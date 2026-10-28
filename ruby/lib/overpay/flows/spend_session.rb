# frozen_string_literal: true

module Overpay
  module Flows
    # A spend authorization in use: open it, place each turn's order under
    # it, close it when done. The marketplace sizes each turn's
    # authorization to what's left of the cap (at most the variant's
    # per-turn maximum) and the seller captures actual cost, so closing
    # never has money to return.
    #
    #   session = client.spend_session(listing_id: "...", cap_cents: 500)
    #   turn = session.order(buyer_note: { model: "default", messages: [] })
    #   session.close
    class SpendSession
      attr_reader :authorization

      def self.open(client, listing_id:, cap_cents:, expires_in_seconds: nil, auth: nil)
        authorization = client.spend_authorizations.create(listing_id: listing_id, cap_cents: cap_cents,
                                                           expires_in_seconds: expires_in_seconds, auth: auth)
        new(client, authorization, auth: auth)
      end

      def initialize(client, authorization, auth: nil)
        @client = client
        @authorization = authorization
        @auth = auth
      end

      def id
        authorization.id
      end

      def listing_id
        authorization.listing_id
      end

      # Place (and pay for) one order under the cap. An exhausted cap raises
      # SpendAuthorizationError (`authorization_exhausted`, with
      # `remaining_cents` in its details).
      def order(buyer_note: nil, variant: nil, client_session_id: nil, idempotency_key: nil)
        @client.orders.create(listing_id: listing_id, buyer_note: buyer_note, variant: variant,
                              spend_authorization_id: id, client_session_id: client_session_id,
                              idempotency_key: idempotency_key, auth: @auth)
      end

      # Place, pay and wait for one turn, streaming its output to the block.
      def turn(buyer_note: nil, variant: nil, client_session_id: nil, **wait_opts, &block)
        created = order(buyer_note: buyer_note, variant: variant, client_session_id: client_session_id)
        unless created.paid?
          raise NotSettled.new(order_id: created.id, payment_status: created.payment&.status || "unpaid",
                               api_message: created.payment&.message, order: created.order)
        end

        waiter = @client.wait(created.id, auth: @auth, **wait_opts)
        block ? waiter.stream(&block) : waiter.wait
      end

      # Re-read what's spent and what's left.
      def refresh
        @authorization = @client.spend_authorizations.get(id, auth: @auth)
      end

      def remaining_cents
        authorization.remaining_cents
      end

      def close
        @authorization = @client.spend_authorizations.close(id, auth: @auth)
      end
    end
  end
end
