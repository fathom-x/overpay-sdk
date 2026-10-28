# frozen_string_literal: true

module Overpay
  module Resources
    # Session spending caps across many orders on one metered listing.
    class SpendAuthorizations < Base
      def create(listing_id:, cap_cents:, expires_in_seconds: nil, auth: nil)
        body = { "listing_id" => listing_id, "cap_cents" => Money.whole_cents(cap_cents) }
        body["expires_in_seconds"] = Integer(expires_in_seconds) unless expires_in_seconds.nil?
        request = Request.post("/api/v1/spend_authorizations", json: body)
        model(Models::SpendAuthorization, execute(request, auth_for(auth)))
      end

      def get(id, auth: nil)
        model(Models::SpendAuthorization, execute(Request.get("/api/v1/spend_authorizations/#{segment(id)}"), auth_for(auth)))
      end

      def close(id, auth: nil)
        request = Request.post("/api/v1/spend_authorizations/#{segment(id)}/close", json: {})
        model(Models::SpendAuthorization, execute(request, auth_for(auth)))
      end
    end
  end
end
