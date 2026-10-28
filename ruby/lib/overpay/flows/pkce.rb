# frozen_string_literal: true

require "securerandom"
require "digest"

module Overpay
  module Flows
    # One PKCE session (RFC 7636, `S256` only - the marketplace rejects
    # `plain`): the verifier (kept secret), the challenge (sent to the
    # authorization server), and an opaque CSRF-style state.
    class Pkce
      attr_reader :verifier, :challenge, :state

      def self.generate
        new(verifier: urlsafe_base64(SecureRandom.random_bytes(32)), state: urlsafe_base64(SecureRandom.random_bytes(16)))
      end

      # base64url without padding (RFC 4648 §5), as PKCE wants it.
      def self.urlsafe_base64(bytes)
        [bytes].pack("m0").tr("+/", "-_").delete("=")
      end

      def initialize(verifier:, state:)
        @verifier = verifier
        @state = state
        @challenge = Pkce.urlsafe_base64(Digest::SHA256.digest(verifier))
      end

      def method
        "S256"
      end

      def inspect
        "#<Overpay::Flows::Pkce challenge=#{challenge} state=#{state} verifier=[redacted]>"
      end
    end

    # The OAuth authorization-code + PKCE flow, minus the browser: register
    # a client, send the user to `authorize_url`, and once the browser comes
    # back to `redirect_uri` with `code` and `state`, `finish` trades them
    # for an API token. Listening on the redirect URI (a loopback address)
    # is the caller's job.
    class PkceFlow
      attr_reader :client_id, :redirect_uri, :scope, :pkce, :authorize_url

      def self.start(client, client_name:, redirect_uri:, scope: "wallet")
        registration = client.oauth.register_client(client_name: client_name, redirect_uris: [redirect_uri], scope: scope)
        resume(client, client_id: registration.client_id, redirect_uri: redirect_uri, scope: scope)
      end

      # A flow for an already-registered client.
      def self.resume(client, client_id:, redirect_uri:, scope: "wallet", pkce: Pkce.generate)
        new(client, client_id: client_id, redirect_uri: redirect_uri, scope: scope, pkce: pkce)
      end

      def initialize(client, client_id:, redirect_uri:, scope:, pkce:)
        @client = client
        @client_id = client_id
        @redirect_uri = redirect_uri
        @scope = scope
        @pkce = pkce
        @authorize_url = client.oauth.authorize_url(client_id: client_id, redirect_uri: redirect_uri,
                                                    code_challenge: pkce.challenge, state: pkce.state, scope: scope)
      end

      # Trade the callback's `code` for an API token; `state` must be this
      # flow's (OAuthStateMismatch otherwise).
      def finish(code:, state:)
        raise OAuthStateMismatch, "OAuth state mismatch" unless state == pkce.state

        @client.oauth.exchange_code(code: code, redirect_uri: redirect_uri, code_verifier: pkce.verifier,
                                    client_id: client_id)
      end
    end
  end
end
