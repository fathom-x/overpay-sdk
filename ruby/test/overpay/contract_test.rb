# frozen_string_literal: true

require "test_helper"
require "set"

# The SDK against the API contract: the spec copy in spec/ and the
# fixtures the marketplace's own tests pin.
class ContractTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)
  SPEC = JSON.parse(File.read(File.join(ROOT, "spec/overpay-v1.json"), encoding: "UTF-8"))
  INDEX = Overpay::Testing.fixture_index

  # Buyer operations this SDK implements, and the method that does.
  IMPLEMENTED = {
    "listListings" => "listings.list", "getListing" => "listings.get", "getSeller" => "sellers.get",
    "listOrders" => "orders.list", "createOrder" => "orders.create", "getOrder" => "orders.get",
    "acceptQuote" => "orders.accept_quote", "declineQuote" => "orders.decline_quote",
    "updateCheckout" => "orders.update_checkout",
    "createSpendAuthorization" => "spend_authorizations.create", "getSpendAuthorization" => "spend_authorizations.get",
    "closeSpendAuthorization" => "spend_authorizations.close",
    "listMerchantCredits" => "credits.list", "listMerchantCreditTransactions" => "credits.transactions",
    "loadCoreCredits" => "credits.load", "getMerchantCreditBalance" => "credits.balance",
    "purchaseMerchantCredits" => "credits.purchase", "redeemMerchantCredits" => "credits.redeem",
    "getAccount" => "account.get", "registerBuyer" => "buyer.register", "createWebSession" => "buyer.web_session",
    "getOAuthMetadata" => "oauth.metadata", "registerOAuthClient" => "oauth.register_client",
    "authorizeOAuth" => "oauth.authorize_url (browser)", "approveOAuth" => "the user's browser",
    "exchangeOAuthToken" => "oauth.exchange_code"
  }.freeze

  # Which model reads each operation's success body, and whether the model
  # is the `data` envelope's payload or the whole body.
  MODELS = {
    "listListings" => [:page, Overpay::Models::Listing], "getListing" => [:data, Overpay::Models::Listing],
    "getSeller" => [:data, Overpay::Models::Seller], "listOrders" => [:page, Overpay::Models::Order],
    "getOrder" => [:data, Overpay::Models::Order], "createOrder" => [:whole, Overpay::Models::CreatedOrder],
    "acceptQuote" => [:data, Overpay::Models::Order], "declineQuote" => [:data, Overpay::Models::Order],
    "updateCheckout" => [:data, Overpay::Models::Order],
    "createSpendAuthorization" => [:data, Overpay::Models::SpendAuthorization],
    "getSpendAuthorization" => [:data, Overpay::Models::SpendAuthorization],
    "closeSpendAuthorization" => [:data, Overpay::Models::SpendAuthorization],
    "listMerchantCredits" => [:list, Overpay::Models::MerchantCredit],
    "listMerchantCreditTransactions" => [:page, Overpay::Models::CreditTransaction],
    "loadCoreCredits" => [:data, Overpay::Models::CreditLoad],
    "getMerchantCreditBalance" => [:data, Overpay::Models::MerchantCreditBalance],
    "purchaseMerchantCredits" => [:data, Overpay::Models::CreditPurchase],
    "redeemMerchantCredits" => [:data, Overpay::Models::Redemption], "getAccount" => [:data, Overpay::Models::Account],
    "registerBuyer" => [:data, Overpay::Models::BuyerRegistration], "createWebSession" => [:data, Overpay::Models::WebSession],
    "getOAuthMetadata" => [:whole, Overpay::Models::OAuthServerMetadata],
    "registerOAuthClient" => [:whole, Overpay::Models::OAuthClient], "exchangeOAuthToken" => [:whole, Overpay::Models::OAuthToken]
  }.freeze

  def test_generated_is_fresh
    load File.join(ROOT, "bin/codegen") unless defined?(Overpay::Codegen)
    rendered = Overpay::Codegen.render(Overpay::Codegen.spec)
    assert_equal rendered, File.read(File.join(ROOT, "lib/overpay/generated.rb")),
                 "lib/overpay/generated.rb is stale: run bin/codegen"
  end

  def test_every_buyer_operation_is_implemented
    buyer = Overpay::OPERATIONS.values.select { |op| op.audience == "buyer" }.map(&:id).to_set
    implemented = IMPLEMENTED.keys.to_set & Overpay::OPERATIONS.keys.to_set
    assert_equal buyer, implemented, "buyer operations in the spec vs. IMPLEMENTED"
  end

  def test_the_operation_table_matches_the_spec
    Overpay::OPERATIONS.each_value do |op|
      found = SPEC.dig("paths", op.path, op.method.downcase, "operationId")
      assert_equal op.id, found, "#{op.method} #{op.path}"
    end
  end

  def test_every_fixture_round_trips_through_its_model
    INDEX.each do |file, entry|
      body = Overpay::Testing.fixture(file.delete_suffix(".json"))
      if entry["status"] >= 400
        error = Overpay::ApiError.from_response(entry["status"], JSON.generate(body))
        assert error.known_code?, "#{file}: error without a known code"
        next
      end
      roundtrip(file, entry["operation"], body)
    end
  end

  # The marketplace's fixtures carry whole cents, but Cents is a number: a
  # balance reads 9990.8444 once sub-cent charges land on it. Every typed
  # model must accept that.
  def test_every_cents_field_accepts_a_fraction
    cents = cents_properties
    assert cents.include?("credit_balance_cents") && cents.include?("balance_cents")
    INDEX.each do |file, entry|
      next if entry["status"] >= 400

      body = fractionalize(Overpay::Testing.fixture(file.delete_suffix(".json")), cents)
      roundtrip(file, entry["operation"], body) do |model|
        walk_models(model) do |m|
          m.class.accessors.each do |key, name|
            next unless cents.include?(key) && m.raw[key].is_a?(Numeric)

            value = m.public_send(name)
            assert_kind_of BigDecimal, value, "#{file}: #{m.class}##{key}"
            assert_equal BigDecimal("0.5"), value.frac, "#{file}: #{m.class}##{key} lost its fraction"
          end
        end
      end
    end
  end

  def test_every_success_fixture_has_a_fake_default_route
    defaults = Overpay::Testing::FakeOverpay::DEFAULT_FIXTURES
    INDEX.each do |_file, entry|
      next if entry["status"] >= 400 || %w[authorizeOAuth approveOAuth].include?(entry["operation"])

      assert defaults.key?(entry["operation"]), "FakeOverpay has no default fixture for #{entry['operation']}"
    end
    defaults.each_value do |stem|
      next unless File.exist?(File.join(Overpay::Testing::FIXTURE_DIR, "#{stem}.json"))

      assert INDEX.key?("#{stem}.json"), "default fixture #{stem} is not in the index"
    end
  end

  def test_typed_views_read_the_interesting_parts
    listing = Overpay::Models::Listing.from_body(Overpay::Testing.fixture("listings_show_variants"))
    assert listing.metered?
    assert_equal "infer", listing.provider_tool.name
    assert_equal [BigDecimal("100"), BigDecimal("2000")], listing.authorization_bounds("premium")
    assert_equal [BigDecimal("5"), BigDecimal("500")], listing.authorization_bounds("cheap")
    assert_equal({ "input_per_mtok_cents" => 10 }, listing.variant("cheap").rate_card)
    refute listing.checkout_required?

    order = Overpay::Models::Order.from_body(Overpay::Testing.fixture("orders_show_rejected"))
    assert order.terminal? && order.rejected?
    assert_equal "authorization_too_low", order.rejection.reason_code
    assert_equal BigDecimal("150"), order.rejection.required_authorization_cents
    assert_equal "refunded", order.refund_status

    offloaded = Overpay::Models::Order.from_body(Overpay::Testing.fixture("orders_show_offloaded"))
    assert offloaded.offloaded? && offloaded.delivered?
    assert_equal 20, offloaded.delivered_content_byte_size

    partial = Overpay::Models::Order.from_body(Overpay::Testing.fixture("orders_show_partial"))
    assert_equal 1, partial.partial_seq
    refute partial.terminal?
    assert_kind_of Time, partial.created_at

    credits = Overpay::Testing.fixture("merchant_credits_index")["data"].map { |c| Overpay::Models::MerchantCredit.new(c) }
    assert credits[0].seller_held? && credits[1].organization_held?
    assert_equal "alice-shop", credits[0].slug
    refute credits[1].core?

    purchase = Overpay::Models::CreditPurchase.from_body(Overpay::Testing.fixture("merchant_credit_purchase"))
    assert_equal BigDecimal("500"), purchase.total_usd_cents, "a decimal string is still cents"

    created = Overpay::Models::CreatedOrder.from_body(Overpay::Testing.fixture("orders_create_unpaid"))
    refute created.paid?
    assert_equal created.order.id, created.id

    token = Overpay::Models::OAuthToken.from_body(Overpay::Testing.fixture("oauth_token"))
    refute_includes token.inspect, token.access_token
  end

  private

  def roundtrip(file, operation, body)
    kind, klass = MODELS.fetch(operation) { flunk "#{file}: no model mapped for #{operation}" }
    model =
      case kind
      when :page
        page = Overpay::Page.new(body, klass)
        assert_equal body["data"], page.data.map(&:raw), "#{file} doesn't survive a typed round trip"
        page.data
      when :list
        list = body["data"].map { |item| klass.new(item) }
        assert_equal body["data"], list.map(&:raw), "#{file} doesn't survive a typed round trip"
        list
      when :data
        m = klass.from_body(body)
        assert_equal body["data"], m.raw, "#{file} doesn't survive a typed round trip"
        m
      when :whole
        m = klass.from_body(body)
        assert_equal body, m.raw, "#{file} doesn't survive a typed round trip"
        m
      end
    Array(model).each { |m| exercise_accessors(file, m) }
    yield model if block_given?
  end

  # Every declared accessor reads without raising (the conversions run).
  def exercise_accessors(file, model)
    walk_models(model) do |m|
      m.class.accessors.each_value do |name|
        m.public_send(name)
      rescue StandardError => e
        flunk "#{file}: #{m.class}##{name} raised #{e.class}: #{e.message}"
      end
    end
  end

  def walk_models(model, &block)
    Array(model).each do |m|
      next unless m.is_a?(Overpay::Model)

      yield m
      m.class.accessors.each_value do |name|
        value = m.public_send(name)
        walk_models(value, &block) if value.is_a?(Overpay::Model) || value.is_a?(Array)
      end
    end
  end

  # Property names the spec types as Cents/NullableCents (directly or
  # through allOf).
  def cents_properties
    out = Set.new
    is_cents = lambda do |schema|
      ref = ->(v) { v.is_a?(Hash) && v["$ref"].to_s.match?(%r{/(Nullable)?Cents\z}) }
      ref.call(schema) || (schema.is_a?(Hash) && Array(schema["allOf"]).any?(&ref))
    end
    walk = lambda do |v|
      case v
      when Hash
        (v["properties"] || {}).each { |name, schema| out << name if is_cents.call(schema) }
        v.each_value(&walk)
      when Array then v.each(&walk)
      end
    end
    walk.call(SPEC["components"]["schemas"])
    out
  end

  def fractionalize(value, cents)
    case value
    when Hash
      value.to_h do |k, v|
        [k, cents.include?(k) && v.is_a?(Integer) ? v + 0.5 : fractionalize(v, cents)]
      end
    when Array then value.map { |v| fractionalize(v, cents) }
    else value
    end
  end
end
