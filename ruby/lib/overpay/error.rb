# frozen_string_literal: true

require "json"

module Overpay
  # Every error this gem raises. Defined here (not only in overpay.rb) so a
  # file that needs the error classes alone - `require "overpay/nip98"` -
  # loads on its own.
  class Error < StandardError; end

  # The request never got an HTTP answer (DNS, TLS, connection, timeout).
  # `ambiguous?` is true when the server may have acted before the answer
  # was lost (a read timeout, a reset mid-response) - a write is then only
  # repeated when the caller opted in.
  class TransportError < Error
    attr_reader :cause_class

    def initialize(message, cause: nil, ambiguous: false)
      super(message)
      @cause_class = cause&.class
      @ambiguous = ambiguous
    end

    def ambiguous?
      @ambiguous
    end
  end

  # A success response that isn't the expected JSON.
  class JsonError < Error; end

  # An auth header couldn't be built: a token with a newline in it, or a
  # NIP-98 signer whose key is invalid.
  class SignError < Error; end

  # A delivered file couldn't be retrieved or wasn't usable.
  class DeliveryError < Error; end

  # An error response from the API: `{"error": "...", "code": "...", ...}`.
  #
  # Prints as `HTTP <status>: <body>`, with the body shortened by
  # `ApiError.describe_body`; `body` keeps it whole. Match on `code`, never
  # on the message - and tolerate codes you don't know (`known_code?`).
  class ApiError < Error
    # Longest response body an error message carries verbatim. Overpay's own
    # errors are a line of JSON; anything longer is not something to print.
    BODY_MAX = 2000

    attr_reader :status, :code, :api_message, :details, :body

    # Parse an error response. Never fails: a body that isn't the API's error
    # JSON leaves `code`/`api_message` nil and keeps the raw text. Returns
    # the subclass for the code (InsufficientCredits, NotFound, ...).
    def self.from_response(status, body)
      text = body.to_s.dup.force_encoding(Encoding::UTF_8)
      text = text.scrub unless text.valid_encoding?
      details = begin
        parsed = JSON.parse(text)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        {}
      end
      message = details["error"].is_a?(String) ? details.delete("error") : nil
      code = details["code"].is_a?(String) ? details.delete("code") : nil
      klass = class_for(code, status)
      klass.new(status: status, code: code, api_message: message, details: details, body: text)
    end

    def self.class_for(code, status)
      case code
      when "insufficient_credits", "no_credits" then InsufficientCredits
      when "not_found" then NotFound
      when "unauthorized", "token_required", "nip98_invalid", "nip98_address_mismatch" then Unauthorized
      when "forbidden" then Forbidden
      when "unknown_variant" then UnknownVariant
      when "authorization_out_of_bounds" then AuthorizationOutOfBounds
      when "authorization_exhausted", "authorization_closed", "authorization_listing_mismatch"
        SpendAuthorizationError
      when "checkout_invalid" then CheckoutInvalid
      when "checkout_incomplete" then CheckoutIncomplete
      when "quote_required", "quote_not_active" then QuoteError
      when /\Aidempotency_/ then IdempotencyError
      when nil
        case status
        when 401 then Unauthorized
        when 403 then Forbidden
        when 404 then NotFound
        else ApiError
        end
      else ApiError
      end
    end

    def initialize(status:, code: nil, api_message: nil, details: {}, body: "")
      @status = status
      @code = code
      @api_message = api_message
      @details = details
      @body = body
      super("HTTP #{status}: #{self.class.describe_body(status, body)}")
    end

    # Whether `code` is one this gem's spec copy lists.
    def known_code?
      !code.nil? && ErrorCode.known?(code)
    end

    # True for errors that mean "the buyer's credits don't cover this":
    # `insufficient_credits` / `no_credits`. For servers that predate error
    # codes it falls back to a 402 or 422 whose body mentions credits.
    def insufficient_credits?
      return %w[insufficient_credits no_credits].include?(code) if code

      [402, 422].include?(status) && body.downcase.include?("credits")
    end

    # A detail field, e.g. `remaining_cents`.
    def detail(key)
      details[key.to_s]
    end

    # A money detail field as BigDecimal cents.
    def detail_cents(key)
      value = detail(key)
      value.nil? ? nil : Money.parse(value)
    end

    # A response body as an error message should show it.
    #
    # A failed request is not always answered by Overpay. A firewall or
    # proxy in front of it answers with a whole web page, and relaying that
    # verbatim once put 221 KB of HTML into a chat. An HTML body is reduced
    # to a sentence naming the page's heading; any other body is cut at
    # BODY_MAX bytes, on a character boundary.
    def self.describe_body(status, body)
      lower = body.downcase
      if lower.include?("<!doctype html") || lower.include?("<html")
        heading = tag_text(body, lower, "h1") || tag_text(body, lower, "title")
        message = +"the server answered with a web page instead of a reply"
        message << " (\"#{heading}\")" if heading
        message << "."
        if status == 403
          message << " The request was blocked before it reached Overpay. Sending the same " \
                     "request again is likely to be blocked again."
        end
        return message
      end
      return body if body.bytesize <= BODY_MAX

      cut = body.byteslice(0, BODY_MAX)
      cut = cut.byteslice(0, cut.bytesize - 1) until cut.valid_encoding?
      "#{cut}... (#{body.bytesize - cut.bytesize} more bytes)"
    end

    # The text of the first `<tag>` element, whitespace collapsed, if it is
    # short enough to be a heading.
    def self.tag_text(body, lower, tag)
      open = lower.index("<#{tag}") or return nil
      close = lower.index(">", open) or return nil
      start = close + 1
      stop = lower.index("</#{tag}", start) or return nil
      text = body[start...stop].split.join(" ")
      text unless text.empty? || text.length > 120 || text.include?("<")
    end
    private_class_method :tag_text
  end

  class InsufficientCredits < ApiError; end
  class NotFound < ApiError; end
  class Unauthorized < ApiError; end
  class Forbidden < ApiError; end
  class UnknownVariant < ApiError; end
  class AuthorizationOutOfBounds < ApiError; end
  class SpendAuthorizationError < ApiError; end
  class IdempotencyError < ApiError; end
  class CheckoutInvalid < ApiError; end
  class CheckoutIncomplete < ApiError; end
  class QuoteError < ApiError; end

  # An order exists but isn't paid (e.g. credits ran short). It stays
  # pending and lapses on its own.
  class NotSettled < Error
    attr_reader :order_id, :payment_status, :api_message, :order

    def initialize(order_id:, payment_status:, api_message: nil, order: nil)
      @order_id = order_id
      @payment_status = payment_status
      @api_message = api_message
      @order = order
      super("order #{order_id} was not paid (#{payment_status}): #{api_message || 'no reason given'}")
    end
  end

  # A quote request the seller declined (or the buyer cancelled).
  class QuoteDeclined < Error
    attr_reader :order

    def initialize(order)
      @order = order
      super("quote for order #{order.id} was declined#{": #{order.quote&.decline_reason}" if order.quote&.decline_reason}")
    end
  end

  # The browser came back from an OAuth login with another flow's `state`.
  class OAuthStateMismatch < Error; end
end
