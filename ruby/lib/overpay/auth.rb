# frozen_string_literal: true

module Overpay
  # The credentials for one request.
  #
  # Signatures (`nip98`, `bearer_signed`) are made per request and per retry
  # over the final URL and method, and for a request with a body they carry
  # NIP-98's `payload` tag: the sha256 of the exact bytes sent. The client
  # serialises a body once and sends those same bytes.
  #
  # A signer is anything responding to `sign_nip98(url:, method:, body:)`
  # with an `Authorization` header value (`"Nostr <base64 event>"`); see
  # Overpay::Nip98::Signer (`require "overpay/nip98"`).
  class Auth
    # The header carrying a NIP-98 signature next to a bearer token.
    SIGNATURE_HEADER = "X-Nostr-Signature"

    attr_reader :kind, :token, :signer

    def initialize(kind, token: nil, signer: nil)
      @kind = kind
      @token = token
      @signer = signer
      freeze
    end

    # No `Authorization` header (public endpoints: listings, sellers).
    NONE = new(:none)

    # An API token: `Authorization: Bearer <token>`.
    def self.bearer(token)
      new(:bearer, token: token.to_s)
    end

    # A NIP-98 signature by a Nostr key in `Authorization: Nostr <event>`.
    def self.nip98(signer)
      new(:nip98, signer: signer)
    end

    # An API token, plus a NIP-98 signature by the buyer's key in
    # `X-Nostr-Signature` - the keyholder's signed authorization of each
    # request (for a spend, of exactly what is bought).
    def self.bearer_signed(token, signer)
      new(:bearer_signed, token: token.to_s, signer: signer)
    end

    # Whatever `value` is - an Auth, a token String, a signer, or nil.
    def self.coerce(value)
      case value
      when Auth then value
      when nil then NONE
      when String then bearer(value)
      else
        raise ArgumentError, "not an auth: #{value.inspect}" unless value.respond_to?(:sign_nip98)

        nip98(value)
      end
    end

    def none?
      kind == :none
    end

    # The headers for `method url` with `body` (the exact bytes sent).
    def headers(method, url, body)
      case kind
      when :none then {}
      when :bearer then { "Authorization" => bearer_value }
      when :nip98 then { "Authorization" => sign(method, url, body) }
      when :bearer_signed
        { "Authorization" => bearer_value, SIGNATURE_HEADER => sign(method, url, body) }
      end
    end

    def inspect
      "#<Overpay::Auth #{kind}>"
    end
    alias to_s inspect

    private

    def bearer_value
      raise SignError, "API token must not contain line breaks" if token.match?(/[\r\n]/)

      "Bearer #{token}"
    end

    def sign(method, url, body)
      signer.sign_nip98(url: url, method: method, body: body)
    rescue SignError
      raise
    rescue StandardError => e
      raise SignError, "nip98 sign: #{e.message}"
    end
  end
end
