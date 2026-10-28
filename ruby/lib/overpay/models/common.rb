# frozen_string_literal: true

module Overpay
  module Models
    class SellerRef < Model
      fields :name, :slug
    end

    class DeliveryEta < Model
      fields :p50_seconds, :p90_seconds, :source
    end

    class ProviderTool < Model
      fields :name
    end
  end
end
