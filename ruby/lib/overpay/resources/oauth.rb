# frozen_string_literal: true

require "uri"

module Overpay
  module Resources
    # OAuth 2.0 authorization code + PKCE (for apps that log a user in
    # through the browser). See Flows::PkceFlow for the whole run.
    class OAuth < Base
      def metadata
        model(Models::OAuthServerMetadata, execute(Request.get("/.well-known/oauth-authorization-server"), Auth::NONE))
      end

      # Dynamic client registration (public client, no secret).
      def register_client(client_name:, redirect_uris:, scope: nil)
        body = { "client_name" => client_name, "redirect_uris" => Array(redirect_uris),
                 "grant_types" => ["authorization_code"], "response_types" => ["code"],
                 "token_endpoint_auth_method" => "none" }
        body["scope"] = scope unless scope.nil?
        model(Models::OAuthClient, execute(Request.post("/oauth/clients", json: body), Auth::NONE))
      end

      # The browser URL that starts a login (on the public host).
      def authorize_url(client_id:, redirect_uri:, code_challenge:, state:, scope: nil, client_name: nil, nip98: nil)
        query = { response_type: "code", client_id: client_id, redirect_uri: redirect_uri,
                  code_challenge: code_challenge, code_challenge_method: "S256", state: state,
                  scope: scope, client_name: client_name, nip98: nip98 }.compact
        client.public_join("/oauth/authorize?#{URI.encode_www_form(query)}")
      end

      # Trade the callback's `code` for an API token.
      def exchange_code(code:, redirect_uri:, code_verifier:, client_id:)
        form = { "grant_type" => "authorization_code", "code" => code, "redirect_uri" => redirect_uri,
                 "code_verifier" => code_verifier, "client_id" => client_id }
        model(Models::OAuthToken, execute(Request.post("/oauth/token", form: form), Auth::NONE))
      end
    end
  end
end
