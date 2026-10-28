# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "overpay"
require "overpay/testing"
require "overpay/nip98"
require "digest"
require "base64"
require "minitest/autorun"

module Overpay
  module TestSupport
    # A client against a FakeOverpay served over a real socket, with sleeps
    # recorded instead of slept.
    def start_fake
      @fake = Overpay::Testing::FakeOverpay.new
      @server = Overpay::Testing::Server.start(@fake)
      @sleeps = []
      @client = Overpay::Client.new(base_url: @server.url, token: "test-token",
                                    retry_policy: Overpay::RetryPolicy.new(max_attempts: 3, base_delay: 0.01, max_delay: 0.05),
                                    sleeper: ->(s) { @sleeps << s })
    end

    def stop_fake
      @client&.close
      @server&.stop
    end

    def fixture(stem)
      Overpay::Testing.fixture(stem)
    end

    # An order snapshot body built from a fixture with `data` overrides.
    def order_body(stem = "orders_show_partial", **overrides)
      body = fixture(stem)
      overrides.each { |k, v| v.nil? ? body["data"].delete(k.to_s) : body["data"][k.to_s] = v }
      body
    end

    # A NIP-98 backend that signs nothing real: deterministic, no libsecp256k1.
    class FakeSchnorr
      def pubkey(secret)
        Digest::SHA256.digest(secret)
      end

      def schnorr_sign(message, secret)
        Digest::SHA256.digest(message + secret) * 2
      end
    end
  end
end
