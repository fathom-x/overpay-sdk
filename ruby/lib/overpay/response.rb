# frozen_string_literal: true

module Overpay
  # A 2xx response: its status, headers and JSON body exactly as the API
  # sent it (`body`), with `data` for the envelope's payload.
  class Response
    # Header the API sets on a replayed idempotent response.
    IDEMPOTENT_REPLAYED_HEADER = "idempotent-replayed"

    attr_reader :status, :headers, :body

    def initialize(status:, headers:, body:)
      @status = status
      @headers = headers
      @body = body
    end

    # The body's `data`, or the whole body when it has none.
    def data
      body.is_a?(Hash) && body.key?("data") ? body["data"] : body
    end

    def next_cursor
      body.is_a?(Hash) ? body["next_cursor"] : nil
    end

    # True when the API replayed an earlier response to the same
    # idempotency key instead of acting again.
    def replayed?
      headers[IDEMPOTENT_REPLAYED_HEADER].to_s == "true"
    end
  end
end
