# frozen_string_literal: true

require "uri"

module Overpay
  module Flows
    # Downloading an offloaded deliverable (`delivered_content_url`).
    module Delivered
      # Largest delivered file `fetch_delivered_content` reads.
      MAX_DELIVERED_CONTENT_BYTES = 16 * 1024 * 1024
      MAX_REDIRECTS = 5

      # What a delivered file's link held.
      DeliveredContent = Data.define(:text, :content_type, :bytes) do
        def text?
          !text.nil?
        end

        def binary?
          text.nil?
        end
      end

      # Inline an offloaded deliverable into an order (a Models::Order or a
      # raw snapshot Hash, enveloped or bare), returning the order with
      # `delivered_content` filled in. Once an order is delivered, the
      # marketplace may hand back a `delivered_content_url` instead of
      # `delivered_content`. Text behind the link is fetched and put in
      # `delivered_content`; a binary file stays a link, with
      # `delivered_content_type` filled in when missing and its size in
      # `delivered_content_bytes`. Undelivered and already-inline orders are
      # returned as they are.
      def resolve_delivered(order)
        snapshot = order.is_a?(Model) ? order.raw : order
        data = snapshot.is_a?(Hash) && snapshot.key?("data") ? snapshot["data"] : snapshot
        return order unless data.is_a?(Hash)
        return order unless data["fulfillment_status"] == FulfillmentStatus::DELIVERED && data["delivered_content"].nil?

        url = data["delivered_content_url"]
        return order if url.nil? || url.to_s.empty?

        content = fetch_delivered_content(url)
        if content.text?
          data["delivered_content"] = content.text
        else
          data["delivered_content_type"] ||= content.content_type if content.content_type
          size = content.bytes || data["delivered_content_byte_size"]
          data["delivered_content_bytes"] = size if size
        end
        order.is_a?(Model) ? order.class.new(order.raw, response: order.response) : order
      end

      # Fetch an order's result when the marketplace delivered it as a file.
      # The link is signed, so no auth header is sent; it must point at this
      # marketplace's own origin (base or public URL) - the redirect it
      # answers with, to blob storage, is followed. Text comes back with
      # `text`; anything else (an image, a PDF, bytes that are not UTF-8) is
      # a successful delivery too, returned as binary (type and size) for
      # the caller to hand on as a link. A file whose Content-Type already
      # says binary is not downloaded at all.
      def fetch_delivered_content(url)
        target = URI.parse(url.to_s)
        unless same_origin?(target, base_uri) || same_origin?(target, public_uri)
          raise DeliveryError, "refusing to fetch from #{target.host || 'an unknown host'}, which is not this marketplace"
        end

        status, headers, body = follow_redirects(target)
        raise ApiError.from_response(status, body) unless (200..299).cover?(status)

        content_type = headers["content-type"].to_s.split(";").first.to_s.strip.downcase
        content_type = nil if content_type.empty?
        if content_type && binary_media_type?(content_type)
          length = headers["content-length"]&.to_i
          return DeliveredContent.new(text: nil, content_type: content_type, bytes: length)
        end
        if body.bytesize > MAX_DELIVERED_CONTENT_BYTES
          raise DeliveryError, "file is #{body.bytesize} bytes, over the #{MAX_DELIVERED_CONTENT_BYTES}-byte limit"
        end

        text = body.dup.force_encoding(Encoding::UTF_8)
        if text.valid_encoding?
          DeliveredContent.new(text: text, content_type: content_type, bytes: body.bytesize)
        else
          DeliveredContent.new(text: nil, content_type: content_type, bytes: body.bytesize)
        end
      end

      BINARY_PREFIXES = %w[image/ audio/ video/ font/].freeze
      BINARY_TYPES = %w[application/pdf application/zip application/gzip application/x-tar application/wasm].freeze

      # Media types that are never text, so there is no point downloading
      # them to find out. Unknown and `application/octet-stream` files are
      # still read and tested for UTF-8 - seller bots upload text as either.
      def binary_media_type?(media_type)
        BINARY_PREFIXES.any? { |p| media_type.start_with?(p) } || BINARY_TYPES.include?(media_type)
      end

      private

      def follow_redirects(uri)
        MAX_REDIRECTS.times do
          status, headers, body = transport.call("GET", uri, { "Accept" => "*/*" }, nil)
          return [status, headers, body] unless [301, 302, 303, 307, 308].include?(status) && headers["location"]

          uri = URI.join(uri.to_s, headers["location"])
        end
        raise DeliveryError, "too many redirects fetching the delivered file"
      end

      def same_origin?(target, known)
        return false if known.nil?

        known.scheme == target.scheme && known.host == target.host && known.port == target.port
      end
    end
  end
end
