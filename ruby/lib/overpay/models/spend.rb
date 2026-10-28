# frozen_string_literal: true

module Overpay
  module Models
    # A session spending cap across many orders on one metered listing.
    class SpendAuthorization < Model
      fields :id, :listing_id, :status, :orders_count
      cents :cap_cents, :spent_cents, :remaining_cents
      times :expires_at, :closed_at, :created_at

      def open?
        status == SpendAuthorizationStatus::OPEN
      end
    end
  end
end
