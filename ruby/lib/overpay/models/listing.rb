# frozen_string_literal: true

module Overpay
  module Models
    # One purchasable option of a listing (for an inference listing, one
    # per model). `rate_card` is seller-published and opaque.
    class ListingVariant < Model
      fields :key, :title, :rate_card, :metadata
      cents :min_authorization_cents, :max_authorization_cents
    end

    # A marketplace listing. The index carries the summary fields; `get`
    # adds the full description, the schemas (checkout, buyer note,
    # delivered content), pricing mode, authorization bounds and variants.
    class Listing < Model
      fields :id, :title, :description, :price_usd, :currency, :category, :condition, :quantity,
             :main_image_url, :delivered_content_type, :checkout_url, :checkout_schema, :buyer_note_schema,
             :delivered_content_schema, :variant_field, :pricing_mode, :listing_type
      cents :price_cents, :min_authorization_cents, :max_authorization_cents
      booleans :free, :requires_shipping_address
      times :published_at, :created_at
      has_one :seller, SellerRef
      has_one :delivery_eta, DeliveryEta
      has_one :provider_tool, ProviderTool
      has_many :variants, ListingVariant

      def metered?
        pricing_mode == PricingMode::METERED
      end

      def fixed?
        pricing_mode.nil? || pricing_mode == PricingMode::FIXED
      end

      # The seller prices the order first (`request_quote`): order, wait for
      # the quote, accept it, then pay.
      def request_quote?
        listing_type == "request_quote"
      end

      def service_lease?
        listing_type == "service_lease"
      end

      # Whether the listing wants buyer input before payment (a shipping
      # address, say). Read off the detail's `checkout_schema` when the
      # marketplace doesn't say so itself.
      def checkout_required?
        return !!raw["checkout_required"] if key?("checkout_required")

        checkout_schema.is_a?(Hash) && !checkout_schema.empty?
      end

      # Only active variants are returned by the buyer API.
      def variant(key)
        (variants || []).find { |v| v.key == key }
      end

      # [min, max] authorization in cents for a metered listing, a
      # variant's own bounds overriding the listing's per side.
      def authorization_bounds(variant_key = nil)
        v = variant_key && variant(variant_key)
        [v&.min_authorization_cents || min_authorization_cents, v&.max_authorization_cents || max_authorization_cents]
      end
    end
  end
end
