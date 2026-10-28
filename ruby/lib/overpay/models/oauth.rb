# frozen_string_literal: true

module Overpay
  module Models
    class OAuthServerMetadata < Model
      whole_body!
      fields :issuer, :authorization_endpoint, :token_endpoint, :registration_endpoint,
             :response_types_supported, :grant_types_supported, :code_challenge_methods_supported
    end

    class OAuthClient < Model
      whole_body!
      fields :client_id, :client_id_issued_at, :redirect_uris, :grant_types, :response_types,
             :token_endpoint_auth_method, :client_name
    end

    class OAuthToken < Model
      whole_body!
      fields :access_token, :token_type, :scope

      def inspect
        "#<Overpay::Models::OAuthToken token_type=#{token_type} scope=#{scope} access_token=[redacted]>"
      end
    end
  end
end
