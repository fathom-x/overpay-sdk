# frozen_string_literal: true

module Overpay
  module Resources
    # A group of API operations. Every method takes `auth:` to override the
    # client's default credentials for that one call.
    class Base
      attr_reader :client

      def initialize(client)
        @client = client
      end

      private

      def execute(request, auth)
        client.execute(request, auth)
      end

      def auth_for(auth)
        auth.nil? ? client.auth : Auth.coerce(auth)
      end

      def model(klass, response)
        klass.from_body(response.body, response: response)
      end

      def page(klass, response)
        Page.new(response.body, klass, response: response)
      end

      def segment(value)
        Request.segment(value)
      end
    end
  end
end
