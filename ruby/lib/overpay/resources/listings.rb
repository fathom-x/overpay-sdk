# frozen_string_literal: true

module Overpay
  module Resources
    # Browse the marketplace (no auth needed).
    class Listings < Base
      # One page of listings (summaries: no schemas, truncated description).
      def list(category: nil, seller: nil, cursor: nil, limit: nil, auth: Auth::NONE)
        request = Request.get("/api/v1/listings", query: { category: category, seller: seller, cursor: cursor, limit: limit })
        page(Models::Listing, execute(request, auth_for(auth)))
      end

      # Every listing, page by page, as a lazy Enumerator.
      def list_all(**query)
        Flows::Pagination.each_item { |cursor| list(**query, cursor: cursor) }
      end

      # One listing in detail: full description, schemas, pricing, variants.
      def get(id, auth: Auth::NONE)
        model(Models::Listing, execute(Request.get("/api/v1/listings/#{segment(id)}"), auth_for(auth)))
      end
    end
  end
end
