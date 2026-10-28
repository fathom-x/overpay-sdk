# frozen_string_literal: true

module Overpay
  module Resources
    class Buyer < Base
      # Register (or sign in) with a Nostr key and mint an API token. Needs
      # NIP-98 auth: pass `auth: Overpay::Auth.nip98(signer)`, or build the
      # client with a `signer:` and no token.
      def register(username: nil, token_name: nil, auth: nil)
        body = {}
        body["username"] = username unless username.nil?
        body["token_name"] = token_name unless token_name.nil?
        request = Request.post("/api/v1/buyer/register", json: body)
        model(Models::BuyerRegistration, execute(request, auth_for(auth)))
      end

      # A one-time browser login link for the token's account.
      def web_session(auth: nil)
        request = Request.post("/api/v1/buyer/web_session", json: {})
        model(Models::WebSession, execute(request, auth_for(auth)))
      end
    end
  end
end
