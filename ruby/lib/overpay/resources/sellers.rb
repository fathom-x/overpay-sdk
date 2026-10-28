# frozen_string_literal: true

module Overpay
  module Resources
    class Sellers < Base
      # A seller's public profile and payout wallets.
      def get(slug, auth: Auth::NONE)
        model(Models::Seller, execute(Request.get("/api/v1/sellers/#{segment(slug)}"), auth_for(auth)))
      end
    end
  end
end
