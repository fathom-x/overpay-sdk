# frozen_string_literal: true

module Overpay
  module Models
    # A seller's public profile and payout wallets.
    class Seller < Model
      fields :name, :slug, :wallets
    end
  end
end
