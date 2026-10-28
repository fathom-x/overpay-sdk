# frozen_string_literal: true

require "json"

module Overpay
  module Resources
    # Orders: list, read, place, and the quote / checkout steps.
    class Orders < Base
      PAY_WITH_CREDITS = "merchant_credits"

      # One page of the buyer's orders, newest first. `ids` returns exactly
      # those orders in detail form; `client_session_id` only the orders
      # placed under that label.
      def list(payment_status: nil, fulfillment_status: nil, client_session_id: nil, ids: nil, cursor: nil,
               limit: nil, payer_address: nil, auth: nil)
        request = Request.get("/api/v1/orders", query: {
          payment_status: payment_status, fulfillment_status: fulfillment_status, cursor: cursor, limit: limit,
          payer_address: payer_address, client_session_id: client_session_id, ids: ids
        })
        page(Models::Order, execute(request, auth_for(auth)))
      end

      def list_all(**query)
        Flows::Pagination.each_item { |cursor| list(**query, cursor: cursor) }
      end

      # One order in detail. `since_seq` is the `partial_seq` you already
      # hold: an unchanged streaming buffer is then left out of the response.
      def get(id, since_seq: nil, payer_address: nil, auth: nil)
        request = Request.get("/api/v1/orders/#{segment(id)}", query: { since_seq: since_seq, payer_address: payer_address })
        model(Models::Order, execute(request, auth_for(auth)))
      end

      # Place an order (Bearer auth). `buyer_note` is free text or a Hash
      # (sent as its JSON text, per the listing's `buyer_note_schema`).
      # `pay: true` (or `:merchant_credits`) settles it with credits in the
      # same request; `authorization_cents` (metered listings) and
      # `spend_authorization_id` imply it. The response's `payment` says
      # how paying went; a redemption failure still returns the pending
      # order. A request_quote listing returns an `awaiting_quote` order.
      def create(listing_id:, buyer_note: nil, variant: nil, quantity: nil, pay: nil, authorization_cents: nil,
                 spend_authorization_id: nil, client_session_id: nil, idempotency_key: nil, auth: nil)
        pay_with_credits = !pay.nil? && pay != false || !authorization_cents.nil? || !spend_authorization_id.nil?
        body = { "listing_id" => listing_id }
        body["buyer_note"] = buyer_note.is_a?(String) ? buyer_note : JSON.generate(buyer_note) unless buyer_note.nil?
        body["variant"] = variant unless variant.nil?
        body["quantity"] = Integer(quantity) unless quantity.nil?
        body["pay"] = PAY_WITH_CREDITS if pay_with_credits
        body["authorization_cents"] = Money.whole_cents(authorization_cents) unless authorization_cents.nil?
        body["spend_authorization_id"] = spend_authorization_id unless spend_authorization_id.nil?
        body["client_session_id"] = client_session_id unless client_session_id.nil?
        request = Request.post("/api/v1/orders", json: body, idempotency_key: idempotency_key || client.auto_idempotency_key)
        model(Models::CreatedOrder, execute(request, auth_for(auth)))
      end

      # Accept the seller's quote on a request_quote order: it becomes a
      # pending order, payable (with credits) for the next hour.
      def accept_quote(id, auth: nil)
        request = Request.post("/api/v1/orders/#{segment(id)}/accept_quote", json: {},
                                                                              idempotency_key: client.auto_idempotency_key)
        model(Models::Order, execute(request, auth_for(auth)))
      end

      # Decline a quote (or withdraw a quote request): the order is cancelled.
      def decline_quote(id, auth: nil)
        request = Request.post("/api/v1/orders/#{segment(id)}/decline_quote", json: {})
        model(Models::Order, execute(request, auth_for(auth)))
      end

      # Supply the buyer input a listing's `checkout_schema` asks for before
      # payment (e.g. `{shipping_address: {...}}`). Accepts an active quote
      # on the way. 422 `checkout_invalid` lists the schema errors.
      def update_checkout(id, checkout_data:, auth: nil)
        request = Request.patch("/api/v1/orders/#{segment(id)}/checkout", json: { "checkout_data" => checkout_data },
                                                                           idempotency_key: client.auto_idempotency_key)
        model(Models::Order, execute(request, auth_for(auth)))
      end
    end
  end
end
