# frozen_string_literal: true

require "json"
require "uri"

module Overpay
  # One API request, for Client#execute - the escape hatch for calls the
  # typed resources don't cover.
  class Request
    # Header carrying a request's idempotency key.
    IDEMPOTENCY_KEY_HEADER = "Idempotency-Key"

    attr_reader :method, :path, :query, :json, :form, :idempotency_key, :accept_json

    # `path` is joined onto the base URL (`/api/v1/...`), or an absolute URL.
    # `query` values that are nil are skipped; Array values repeat the key
    # with `[]`. `json` is a Hash/Array body; `form` a Hash of form fields.
    def initialize(method, path, query: {}, json: nil, form: nil, idempotency_key: nil, accept_json: true)
      @method = method.to_s.upcase
      @path = path.to_s
      @query = query.compact
      @json = json
      @form = form
      @idempotency_key = idempotency_key
      @accept_json = accept_json
    end

    def self.get(path, **opts)
      new(:get, path, **opts)
    end

    def self.post(path, **opts)
      new(:post, path, **opts)
    end

    def self.patch(path, **opts)
      new(:patch, path, **opts)
    end

    def with(idempotency_key: @idempotency_key)
      self.class.new(method, path, query: query, json: json, form: form, idempotency_key: idempotency_key,
                                   accept_json: accept_json)
    end

    def retryable?
      %w[GET HEAD].include?(method) || !idempotency_key.nil?
    end

    def read?
      %w[GET HEAD].include?(method)
    end

    # The query string, or nil when there is none.
    def query_string
      return nil if query.empty?

      pairs = query.flat_map do |key, value|
        Array(value).map { |v| [value.is_a?(Array) ? "#{key}[]" : key.to_s, v.to_s] }
      end
      URI.encode_www_form(pairs)
    end

    # The body as the bytes to send and their content type, or nil. The
    # body is serialised once, here: a signature's `payload` tag is the hash
    # of these exact bytes, and these are the bytes sent.
    def encoded_body
      if !json.nil?
        [JSON.generate(json), "application/json"]
      elsif form
        [URI.encode_www_form(form), "application/x-www-form-urlencoded"]
      end
    end

    # A path segment, percent-encoded.
    def self.segment(value)
      URI.encode_www_form_component(value.to_s).gsub("+", "%20")
    end
  end
end
