# frozen_string_literal: true

require "test_helper"

class ModelsTest < Minitest::Test
  include Overpay::TestSupport

  def test_model_basics
    order = Overpay::Models::Order.new(fixture("orders_show_delivered")["data"].merge("brand_new" => 1))
    assert order.key?(:id) && order.key?("brand_new")
    assert_equal({ "brand_new" => 1 }, order.extra)
    assert_equal 1, order["brand_new"]
    assert_equal order, Overpay::Models::Order.new(order.raw)
    assert_equal order.hash, Overpay::Models::Order.new(order.raw).hash
    refute_equal order, Overpay::Models::Listing.new(order.raw)
    assert_equal JSON.generate(order.raw), order.to_json
    assert_match(/\A#<Overpay::Models::Order /, order.inspect)
    assert_raises(ArgumentError) { Overpay::Models::Order.new(nil) }
    assert_equal({ "id" => :id }, Overpay::Models::Account.accessors.slice("id")) if Overpay::Models::Account.accessors.key?("id")
  end

  def test_order_reads_delivered_json_and_legacy_error_deliveries
    base = fixture("orders_show_delivered")["data"]
    json = Overpay::Models::Order.new(base.merge("delivered_content" => '{"text":"hi","usage":{"t":1}}'))
    assert_equal({ "text" => "hi", "usage" => { "t" => 1 } }, json.delivered_json)
    assert_nil json.delivered_error
    legacy = Overpay::Models::Order.new(base.merge("delivered_content" => '{"error":true,"reason_code":"authorization_too_low"}'))
    assert_equal "authorization_too_low", legacy.delivered_error["reason_code"]
    plain = Overpay::Models::Order.new(base.merge("delivered_content" => "just text"))
    assert_nil plain.delivered_json
    assert_nil Overpay::Models::Order.new(base.merge("delivered_content" => "42")).delivered_json
    assert_nil Overpay::Models::Order.new(base.merge("delivered_content" => nil)).delivered_json
  end

  def test_order_quote_and_checkout_predicates
    base = fixture("orders_show_delivered")["data"]
    bare = Overpay::Models::Order.new(base.reject { |k, _| %w[quote checkout].include?(k) })
    assert bare.checkout_complete?, "no checkout block means nothing to complete"
    refute bare.quote_declined?
    quoted = Overpay::Models::Order.from_body(fixture("orders_show_quoted"))
    assert quoted.quoted? && !quoted.awaiting_quote? && !quoted.paid?
    assert_kind_of Time, quoted.quote.expires_at
    refute Overpay::Models::Quote.new({ "declined" => false, "expires_at" => (Time.now + 60).utc.iso8601 }).expired?
    assert Overpay::Models::Quote.new({ "declined" => false, "expires_at" => (Time.now - 60).utc.iso8601 }).expired?
    refute Overpay::Models::Quote.new({ "declined" => false }).expired?
    declined = Overpay::Models::Order.from_body(fixture("orders_show_quote_declined"))
    assert declined.quote_declined?, "a cancelled quote request reads as declined"
    assert_nil declined.quote.decline_reason, "with no seller reason when the buyer withdrew it"
    checked = Overpay::Models::Order.from_body(fixture("orders_checkout"))
    assert checked.checkout.required? && checked.checkout_complete? && checked.payable?
    assert_equal "Bob", checked.checkout.data.dig("shipping_address", "first_name")
    awaiting = Overpay::Models::Order.from_body(fixture("orders_create_awaiting_quote"))
    assert awaiting.awaiting_quote? && awaiting.quote.nil? && !awaiting.checkout_complete?
  end

  def test_listing_predicates
    quote = Overpay::Models::Listing.new(fixture("listings_show_variants")["data"].merge(
      "listing_type" => "request_quote", "requires_shipping_address" => true, "checkout_required" => true
    ))
    assert quote.request_quote? && quote.requires_shipping_address? && quote.checkout_required?
    refute quote.service_lease?
    lease = Overpay::Models::Listing.new({ "id" => "1", "listing_type" => "service_lease", "checkout_schema" => { "type" => "object" } })
    assert lease.service_lease? && lease.checkout_required?, "falls back to the schema when the flag is absent"
    assert lease.fixed?, "no pricing_mode reads as fixed"
    refute Overpay::Models::Listing.new({ "id" => "1", "checkout_schema" => {} }).checkout_required?
    assert_equal [nil, nil], Overpay::Models::Listing.new({ "id" => "1" }).authorization_bounds("none")
    index = Overpay::Page.new(fixture("listings_index"), Overpay::Models::Listing).first
    assert_equal "fixed_price", index.listing_type
    assert index.requires_shipping_address?
  end

  def test_credit_models_and_enums
    credits = fixture("merchant_credits_index")["data"].map { |c| Overpay::Models::MerchantCredit.new(c) }
    assert_equal "acme", credits[1].slug
    assert_kind_of Time, credits[0].updated_at
    tx = Overpay::Page.new(fixture("merchant_credit_transactions"), Overpay::Models::CreditTransaction).first
    refute tx.load? || tx.refund?
    auth = Overpay::Models::SpendAuthorization.from_body(fixture("spend_authorization_close"))
    refute auth.open?
    outcome = Overpay::Models::PaymentOutcome.new({ "status" => "failed", "message" => "nope" })
    assert_equal "nope", outcome.message
    refute outcome.settled?
    assert Overpay::ErrorCode.known?("checkout_incomplete")
    refute Overpay::ErrorCode.known?("made_up")
    assert Overpay::ListingType.known?("request_quote")
    assert_equal "POST", Overpay::OPERATIONS.fetch("acceptQuote").method
    assert_equal "buyer", Overpay::OPERATIONS.fetch("createOrder").audience
    assert_equal "seller", Overpay::OPERATIONS.fetch("sellerListOrders").audience
    refute Overpay::RetryPolicy.none.retries?
  end
end
