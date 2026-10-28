# frozen_string_literal: true

module Overpay
  module Flows
    # A paid order: its id, how paying went, and the order as created.
    Settled = Data.define(:order_id, :status, :amount_redeemed_cents, :order) do
      def already_paid?
        status == PaymentOutcomeStatus::ALREADY_PAID
      end
    end

    # Placing an order and paying for it with merchant credits.
    module Pay
      # Create and pay an order in one call: `pay: merchant_credits`, plus
      # `authorization_cents` on a metered listing (the most the seller may
      # charge; the rest comes back when it captures). All-or-nothing with
      # an authorization: if credits don't cover it the API cancels the
      # order and this raises InsufficientCredits. Without one, an order
      # whose redemption fails is left pending and raises NotSettled.
      def place_and_pay(listing_id:, buyer_note: nil, variant: nil, quantity: nil, authorization_cents: nil,
                        spend_authorization_id: nil, client_session_id: nil, idempotency_key: nil, auth: nil)
        created = orders.create(listing_id: listing_id, buyer_note: buyer_note, variant: variant, quantity: quantity,
                                pay: true, authorization_cents: authorization_cents,
                                spend_authorization_id: spend_authorization_id, client_session_id: client_session_id,
                                idempotency_key: idempotency_key, auth: auth)
        settled_from(created)
      end

      # Create an unpaid order - the first step of paying in two calls, so
      # the caller can look at its price before `pay_with_credits`.
      def create_unpaid_order(listing_id:, buyer_note: nil, variant: nil, quantity: nil, client_session_id: nil,
                              idempotency_key: nil, auth: nil)
        orders.create(listing_id: listing_id, buyer_note: buyer_note, variant: variant, quantity: quantity,
                      client_session_id: client_session_id, idempotency_key: idempotency_key, auth: auth)
      end

      # Pay a pending order with credits held at `seller_slug` (or its
      # organization). Returns the Redemption only when the order ends up
      # paid; raises NotSettled otherwise.
      def pay_with_credits(seller_slug, order_id, auth: nil)
        redemption = credits.redeem(seller_slug, order_id: order_id, auth: auth)
        unless redemption.settled?
          raise NotSettled.new(order_id: order_id, payment_status: redemption.status, api_message: redemption.message)
        end

        redemption
      end

      private

      def settled_from(created)
        order = created.order
        payment = created.payment
        if payment.nil?
          status = order.paid? ? PaymentOutcomeStatus::ALREADY_PAID : "unpaid"
          raise NotSettled.new(order_id: order.id, payment_status: status, order: order) unless order.paid?

          return Settled.new(order_id: order.id, status: status, amount_redeemed_cents: nil, order: order)
        end
        unless payment.settled?
          raise NotSettled.new(order_id: order.id, payment_status: payment.status, api_message: payment.message,
                               order: order)
        end

        Settled.new(order_id: order.id, status: payment.status, amount_redeemed_cents: payment.amount_redeemed_cents,
                    order: order)
      end
    end
  end
end
