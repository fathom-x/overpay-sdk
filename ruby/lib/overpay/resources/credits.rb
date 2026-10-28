# frozen_string_literal: true

module Overpay
  module Resources
    # Merchant credits: the API's way to pay for an order.
    class Credits < Base
      # Every credit the buyer holds with a balance, by holder.
      def list(auth: nil)
        response = execute(Request.get("/api/v1/merchant_credits"), auth_for(auth))
        Array(response.data).map { |c| Models::MerchantCredit.new(c, response: response) }
      end

      # The balance spendable at one seller.
      def balance(seller_slug, auth: nil)
        request = Request.get("/api/v1/merchant_credits/#{segment(seller_slug)}")
        model(Models::MerchantCreditBalance, execute(request, auth_for(auth)))
      end

      # One page of the buyer's credit ledger, newest first.
      def transactions(since: nil, credit_id: nil, limit: nil, cursor: nil, auth: nil)
        since = since.utc.iso8601 if since.respond_to?(:utc)
        request = Request.get("/api/v1/merchant_credits/transactions",
                              query: { since: since, credit_id: credit_id, limit: limit, cursor: cursor })
        page(Models::CreditTransaction, execute(request, auth_for(auth)))
      end

      def transactions_all(**query)
        Flows::Pagination.each_item { |cursor| transactions(**query, cursor: cursor) }
      end

      # Load core credits over Lightning: a BOLT11 invoice for `amount_cents`.
      def load(amount_cents:, auth: nil)
        request = Request.post("/api/v1/merchant_credits/load", json: { "amount_cents" => Money.json_cents(amount_cents) },
                                                                idempotency_key: client.auto_idempotency_key)
        model(Models::CreditLoad, execute(request, auth_for(auth)))
      end

      # Open a credit-purchase order at a seller (paid in USDC to the
      # returned address, or in the browser at `order_url`).
      def purchase(seller_slug, amount_cents:, auth: nil)
        request = Request.post("/api/v1/merchant_credits/#{segment(seller_slug)}/purchase",
                               json: { "amount_cents" => Money.json_cents(amount_cents) },
                               idempotency_key: client.auto_idempotency_key)
        model(Models::CreditPurchase, execute(request, auth_for(auth)))
      end

      # Apply credits held at `seller_slug` (or its organization) to an order.
      def redeem(seller_slug, order_id:, auth: nil)
        request = Request.post("/api/v1/merchant_credits/#{segment(seller_slug)}/redeem",
                               json: { "order_id" => order_id })
        model(Models::Redemption, execute(request, auth_for(auth)))
      end
    end
  end
end
