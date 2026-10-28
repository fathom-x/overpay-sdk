# frozen_string_literal: true

# Client SDK for the Overpay marketplace buyer API.
#
# The API is described by an OpenAPI document. This gem carries a copy
# (`spec/`) together with the contract fixtures the marketplace's own tests
# pin, and its tests check the SDK against both.
#
#   client = Overpay::Client.new(base_url: "https://overpay.example", token: ENV["OVERPAY_TOKEN"])
#   paid = client.place_and_pay(listing_id: "...", buyer_note: { prompt: "hi" }, authorization_cents: 50)
#   client.wait(paid.order_id) { |event| print event.delta if event.delta }
#
# - Overpay::Client - one marketplace. Resources hang off it: `listings`,
#   `sellers`, `orders`, `credits`, `spend_authorizations`, `account`,
#   `buyer`, `oauth`; higher-level flows are methods on the client
#   (`place_and_pay`, `wait`, `resolve_delivered`, `wallet`, `spend_session`).
# - Overpay::Auth - per request: none, a bearer token, or a NIP-98 signature
#   (`require "overpay/nip98"`), signed per attempt over the final URL.
# - Every model keeps the JSON exactly as sent (`raw`) with typed accessors
#   on top; money fields are BigDecimal cents (Overpay::Money).
# - Overpay::ApiError carries the API's machine-readable `code`.
# - Safe retries: GETs, and order creation under an automatic Idempotency-Key.
module Overpay
  class Error < StandardError; end
end

require_relative "overpay/version"
require_relative "overpay/money"
require_relative "overpay/error"
require_relative "overpay/generated"
require_relative "overpay/auth"
require_relative "overpay/retry_policy"
require_relative "overpay/transport"
require_relative "overpay/request"
require_relative "overpay/response"
require_relative "overpay/model"
require_relative "overpay/models/common"
require_relative "overpay/models/listing"
require_relative "overpay/models/seller"
require_relative "overpay/models/order"
require_relative "overpay/models/credits"
require_relative "overpay/models/spend"
require_relative "overpay/models/account"
require_relative "overpay/models/oauth"
require_relative "overpay/resources/base"
require_relative "overpay/resources/listings"
require_relative "overpay/resources/sellers"
require_relative "overpay/resources/orders"
require_relative "overpay/resources/credits"
require_relative "overpay/resources/spend_authorizations"
require_relative "overpay/resources/account"
require_relative "overpay/resources/buyer"
require_relative "overpay/resources/oauth"
require_relative "overpay/flows/pagination"
require_relative "overpay/flows/pay"
require_relative "overpay/flows/delivered"
require_relative "overpay/flows/waiter"
require_relative "overpay/flows/spend_session"
require_relative "overpay/flows/wallet"
require_relative "overpay/flows/pkce"
require_relative "overpay/client"
