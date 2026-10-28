# frozen_string_literal: true

require "json"

module Overpay
  module Models
    # Why a seller rejected a paid order.
    class Rejection < Model
      fields :reason_code, :message
      cents :estimated_cost_cents, :required_authorization_cents
    end

    class OrderListingRef < Model
      fields :id, :title, :delivered_content_schema
    end

    # A seller's quote on a request_quote order.
    class Quote < Model
      fields :description, :product_image_url, :decline_reason
      booleans :declined
      times :expires_at, :quoted_at

      def expired?
        !expires_at.nil? && expires_at <= Time.now
      end
    end

    # Where an order's pre-payment buyer input (e.g. a shipping address) stands.
    class Checkout < Model
      fields :data
      booleans :required, :complete
    end

    # An order. List responses carry the summary fields; `orders.get` (and
    # a list by `ids`) adds the detail fields: the deliverable, inline or
    # offloaded, and a streaming seller's output so far.
    class Order < Model
      fields :id, :payment_status, :fulfillment_status, :product_title, :product_price_usd, :total_usd,
             :refund_status, :fulfillment_error, :spend_authorization_id, :platform_fee_usd, :buyer_note,
             :variant_key, :client_session_id, :order_url, :delivered_content_type, :tracking_number, :carrier,
             :tracking_url, :delivery_skew_seconds, :settlement_tx_hash, :delivered_content, :delivered_content_url,
             :delivered_content_byte_size, :delivered_content_filename, :partial_seq, :partial_content, :quantity
      cents :product_price_cents, :total_usd_cents, :settled_amount_cents, :refunded_cents, :authorized_cents,
            :captured_cents, :released_cents, :seller_revenue_cents, :platform_fee_cents
      booleans :free
      times :created_at, :paid_at, :delivered_at, :expected_delivered_at
      has_one :rejection, Rejection
      has_one :listing, OrderListingRef
      has_one :quote, Quote
      has_one :checkout, Checkout

      # Delivered, failed, cancelled or rejected: nothing more will happen.
      def terminal?
        FulfillmentStatus::TERMINAL.include?(fulfillment_status)
      end

      def delivered?
        fulfillment_status == FulfillmentStatus::DELIVERED
      end

      def rejected?
        fulfillment_status == FulfillmentStatus::REJECTED
      end

      def paid?
        payment_status == PaymentStatus::PAID
      end

      def awaiting_quote?
        payment_status == PaymentStatus::AWAITING_QUOTE
      end

      def quoted?
        payment_status == PaymentStatus::QUOTED
      end

      def quote_declined?
        !!quote&.declined?
      end

      # Pending: credits can still be applied (until `payment_expires_at`).
      def payable?
        payment_status == PaymentStatus::PENDING
      end

      def checkout_complete?
        checkout.nil? ? true : checkout.complete?
      end

      # The deliverable is offloaded to a file (`delivered_content_url`)
      # rather than inline; see Client#resolve_delivered.
      def offloaded?
        delivered_content.nil? && !delivered_content_url.to_s.empty?
      end

      # `delivered_content` parsed as JSON when it is a JSON document
      # (sellers with a `delivered_content_schema` deliver one), else nil.
      def delivered_json
        text = delivered_content
        return nil unless text.is_a?(String)

        parsed = JSON.parse(text)
        parsed.is_a?(Hash) || parsed.is_a?(Array) ? parsed : nil
      rescue JSON::ParserError
        nil
      end

      # Older sellers delivered a refusal as `{error: true, reason_code}`
      # instead of rejecting; this reads it like a rejection.
      def delivered_error
        json = delivered_json
        return nil unless json.is_a?(Hash) && json["error"]

        json
      end
    end

    # How paying for a new order with `pay: merchant_credits` went.
    class PaymentOutcome < Model
      fields :status, :error
      cents :amount_redeemed_cents

      def settled?
        [PaymentOutcomeStatus::FULLY_PAID, PaymentOutcomeStatus::ALREADY_PAID].include?(status)
      end

      def message
        error || raw["message"]
      end
    end

    # The response to creating an order: the order, and - when paid in the
    # same call - how paying went.
    class CreatedOrder < Model
      whole_body!
      has_one :order, Order, "data"
      has_one :payment, PaymentOutcome

      def id
        order.id
      end

      def paid?
        !!payment&.settled?
      end
    end
  end
end
