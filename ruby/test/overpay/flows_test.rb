# frozen_string_literal: true

require "test_helper"

class FlowsTest < Minitest::Test
  include Overpay::TestSupport

  def setup
    start_fake
  end

  def teardown
    stop_fake
  end

  def test_place_and_pay_in_one_call
    settled = @client.place_and_pay(listing_id: "L1", buyer_note: "hi", authorization_cents: 50)
    assert_equal "fully_paid", settled.status
    assert_equal BigDecimal("50"), settled.amount_redeemed_cents
    assert settled.order.paid?
    assert_equal "merchant_credits", @fake.last_request.json["pay"]
  end

  def test_place_and_pay_raises_when_credits_run_short
    @fake.stub(:post, "/api/v1/orders", status: 402, body: fixture("error_insufficient_credits"))
    assert_raises(Overpay::InsufficientCredits) { @client.place_and_pay(listing_id: "L1", authorization_cents: 50) }

    body = fixture("orders_create_unpaid")
    body["payment"] = { "status" => "failed", "error" => "No credits" }
    @fake.stub(:post, "/api/v1/orders", status: 201, body: body)
    error = assert_raises(Overpay::NotSettled) { @client.place_and_pay(listing_id: "L1") }
    assert_equal body["data"]["id"], error.order_id
    assert_equal "failed", error.payment_status
    assert_match(/No credits/, error.message)
  end

  def test_two_step_pay
    @fake.stub(:post, "/api/v1/orders", status: 201, body: fixture("orders_create_unpaid"))
    created = @client.create_unpaid_order(listing_id: "L1")
    refute @fake.last_request.json.key?("pay")
    refute created.paid?
    redemption = @client.pay_with_credits("alice-shop", created.id)
    assert redemption.settled?
    assert_equal({ "order_id" => created.id }, @fake.last_request.json)

    @fake.stub(:post, "/api/v1/merchant_credits/alice-shop/redeem", body: { data: { status: "partial", amount_redeemed_cents: 5, message: "short" } })
    assert_raises(Overpay::NotSettled) { @client.pay_with_credits("alice-shop", created.id) }
  end

  def test_pagination_walks_cursors_and_stops_on_a_repeat
    pages = [
      { "data" => [{ "id" => "a" }], "next_cursor" => "c1" },
      { "data" => [{ "id" => "b" }], "next_cursor" => "c2" },
      { "data" => [{ "id" => "c" }], "next_cursor" => "c1" }, # a cursor already followed
      { "data" => [{ "id" => "never" }], "next_cursor" => nil }
    ]
    @fake.stub(:get, "/api/v1/orders") { |_r| [200, pages.shift, {}] }
    ids = @client.orders.list_all(client_session_id: "s").map(&:id).to_a
    assert_equal %w[a b c], ids
    assert_equal [nil, "c1", "c2"], @fake.requests.map { |r| r.query["cursor"] }
    assert_equal "s", @fake.requests.first.query["client_session_id"]
  end

  def test_pagination_is_lazy
    @fake.stub(:get, "/api/v1/listings", times: 5) { |_r| [200, fixture("listings_index"), {}] }
    assert_equal 1, @client.listings.list_all.first(1).size
    assert_equal 1, @fake.requests.size
  end

  def test_spend_session
    session = @client.spend_session(listing_id: "L1", cap_cents: 500, expires_in_seconds: 60)
    authorization = fixture("spend_authorization_create")["data"]
    assert_equal authorization["id"], session.id
    created = session.order(buyer_note: { model: "cheap" })
    assert_equal({ "listing_id" => authorization["listing_id"], "buyer_note" => '{"model":"cheap"}',
                   "pay" => "merchant_credits", "spend_authorization_id" => session.id }, @fake.last_request.json)
    assert created.paid?
    assert_equal BigDecimal("500"), session.refresh.remaining_cents
    assert_equal "closed", session.close.status

    @fake.stub(:post, "/api/v1/orders", status: 422, body: { error: "cap spent", code: "authorization_exhausted", remaining_cents: 3 })
    error = assert_raises(Overpay::SpendAuthorizationError) { session.order }
    assert_equal BigDecimal("3"), error.detail_cents(:remaining_cents)
  end

  def test_spend_session_turn_streams
    polls = [order_body(partial_seq: 1, partial_content: "Hi"),
             order_body(fulfillment_status: "delivered", partial_seq: nil, partial_content: nil, delivered_content: "Hi there")]
    @fake.stub(:get, "/api/v1/orders/#{fixture('orders_create_paid')['data']['id']}") { [200, polls.shift, {}] }
    session = @client.spend_session(listing_id: "L1", cap_cents: 500)
    chunks = []
    final = session.turn(buyer_note: "x", poll: 0.01) { |d| chunks << d }
    assert_equal ["Hi", " there"], chunks
    assert final.done?
  end

  def test_wallet
    wallet = @client.wallet
    assert_equal 2, wallet.balances.size
    assert_nil wallet.core, "the fixture holds no core credit"
    assert_equal BigDecimal("0"), wallet.core_balance_cents
    assert_equal BigDecimal("700"), wallet.balance_at("alice-shop").balance_cents
    assert wallet.ledger.first.spend?
    load = wallet.load_core(amount_cents: 1000)
    assert_equal 20_000, load.sats
    purchase = wallet.buy_seller_credits("alice-shop", amount_cents: 500)
    assert_equal "credit_purchase", purchase.order_type

    polls = [order_body(payment_status: "pending"), order_body(payment_status: "pending"), order_body(payment_status: "paid")]
    @fake.stub(:get, "/api/v1/orders/#{load.order_id}") { [200, polls.shift, {}] }
    order = wallet.wait_for_load(load.order_id, poll: 1, timeout: 60)
    assert order.paid?
    assert_equal [1, 1], @sleeps
  end

  def test_wallet_wait_for_load_gives_up_on_timeout_or_expiry
    @fake.stub(:get, "/api/v1/orders/x", body: order_body(payment_status: "pending"), times: 10)
    clock = 0.0
    @client.define_singleton_method(:sleeper) { ->(s) { clock += s } }
    order = @client.wallet.wait_for_load("x", poll: 5, timeout: 12)
    refute order.paid?
    @fake.stub(:get, "/api/v1/orders/y", body: order_body(payment_status: "expired"))
    assert_equal "expired", @client.wallet.wait_for_load("y").payment_status
  end

  def test_pkce_flow
    flow = Overpay::Flows::PkceFlow.start(@client, client_name: "app", redirect_uri: "http://127.0.0.1:9/cb")
    uri = URI.parse(flow.authorize_url)
    params = URI.decode_www_form(uri.query).to_h
    assert_equal "/oauth/authorize", uri.path
    assert_equal fixture("oauth_client")["client_id"], params["client_id"]
    assert_equal "S256", params["code_challenge_method"]
    assert_equal flow.pkce.challenge, params["code_challenge"]
    assert_equal Base64.urlsafe_encode64(Digest::SHA256.digest(flow.pkce.verifier), padding: false), flow.pkce.challenge
    assert_raises(Overpay::OAuthStateMismatch) { flow.finish(code: "c", state: "other") }
    token = flow.finish(code: "c", state: flow.pkce.state)
    assert_equal "test-token-placeholder", token.access_token
    assert_equal flow.pkce.verifier, URI.decode_www_form(@fake.last_request.body).to_h["code_verifier"]
    refute_includes flow.pkce.inspect, flow.pkce.verifier
  end

  def test_quote_flow
    awaiting = order_body("orders_create_unpaid", payment_status: "awaiting_quote", quote: nil,
                                                  checkout: { "required" => true, "complete" => false, "data" => nil })
    awaiting.delete("payment")
    @fake.stub(:post, "/api/v1/orders", status: 201, body: awaiting)
    order = @client.request_quote(listing_id: "L1", buyer_note: "a thing", quantity: 2)
    assert order.awaiting_quote?
    assert_equal 2, @fake.last_request.json["quantity"]
    refute @fake.last_request.json.key?("pay")

    quoted = order_body("orders_show_delivered", payment_status: "quoted", fulfillment_status: "pending",
                                                 quote: { "description" => "Found it", "expires_at" => "2030-01-01T00:00:00Z",
                                                          "quoted_at" => "2026-01-01T00:00:00Z", "declined" => false,
                                                          "decline_reason" => nil, "product_image_url" => nil })
    polls = [awaiting, awaiting, quoted]
    @fake.stub(:get, "/api/v1/orders/#{order.id}") { [200, polls.shift, {}] }
    quoted_order = @client.wait_for_quote(order.id, poll: 1)
    assert quoted_order.quoted?
    assert_equal "Found it", quoted_order.quote.description
    refute quoted_order.quote.expired?

    pending = order_body("orders_show_delivered", payment_status: "pending", fulfillment_status: "pending",
                                                  checkout: { "required" => true, "complete" => true,
                                                              "data" => { "shipping_address" => { "name" => "Bob" } } })
    @fake.stub(:patch, "/api/v1/orders/#{order.id}/checkout", body: pending)
    checked = @client.checkout(order.id, shipping_address: { name: "Bob" })
    assert_equal({ "checkout_data" => { "shipping_address" => { "name" => "Bob" } } }, @fake.last_request.json)
    assert checked.checkout_complete? && checked.payable?

    @fake.stub(:post, "/api/v1/orders/#{order.id}/accept_quote", body: pending)
    assert @client.orders.accept_quote(order.id).payable?

    declined = order_body("orders_show_delivered", payment_status: "cancelled", fulfillment_status: "cancelled",
                                                   quote: { "declined" => true, "decline_reason" => "out of stock" })
    @fake.stub(:post, "/api/v1/orders/#{order.id}/decline_quote", body: declined)
    assert @client.orders.decline_quote(order.id).quote_declined?
    @fake.stub(:get, "/api/v1/orders/#{order.id}", body: declined)
    error = assert_raises(Overpay::QuoteDeclined) { @client.wait_for_quote(order.id) }
    assert_match(/out of stock/, error.message)

    @fake.stub(:patch, "/api/v1/orders/#{order.id}/checkout", status: 422,
                                                                body: { error: "bad", code: "checkout_invalid", errors: ["name is required"] })
    error = assert_raises(Overpay::CheckoutInvalid) { @client.checkout(order.id, shipping_address: {}) }
    assert_equal ["name is required"], error.detail(:errors)
  end
end

class FlowsEdgeTest < Minitest::Test
  include Overpay::TestSupport

  def setup
    start_fake
  end

  def teardown
    stop_fake
  end

  def test_place_and_pay_reads_an_order_born_paid_without_a_payment_key
    body = fixture("orders_create_paid")
    body.delete("payment")
    @fake.stub(:post, "/api/v1/orders", status: 201, body: body)
    settled = @client.place_and_pay(listing_id: "L1")
    assert settled.already_paid?
    assert_nil settled.amount_redeemed_cents

    unpaid = fixture("orders_create_unpaid")
    unpaid.delete("payment")
    @fake.stub(:post, "/api/v1/orders", status: 201, body: unpaid)
    error = assert_raises(Overpay::NotSettled) { @client.place_and_pay(listing_id: "L1") }
    assert_equal "unpaid", error.payment_status
    assert_equal unpaid["data"]["id"], error.order.id
  end

  def test_spend_session_turn_refuses_an_unpaid_turn
    body = fixture("orders_create_unpaid")
    body["payment"] = { "status" => "failed", "error" => "No credits", "code" => "no_credits" }
    @fake.stub(:post, "/api/v1/orders", status: 201, body: body)
    session = @client.spend_session(listing_id: "L1", cap_cents: 100)
    error = assert_raises(Overpay::NotSettled) { session.turn(buyer_note: "x") }
    assert_equal "failed", error.payment_status
  end

  def test_delivered_fetch_limits_redirects_and_keeps_non_utf8_as_binary
    7.times { |i| @fake.stub(:get, "/hop#{i}", status: 302, body: "", headers: { "Location" => "/hop#{i + 1}" }) }
    assert_raises(Overpay::DeliveryError) { @client.fetch_delivered_content("#{@server.url}/hop0") }

    @fake.stub(:get, "/bytes", status: 200, body: "\xFF\xFE\x00".b, headers: { "Content-Type" => "application/octet-stream" })
    content = @client.fetch_delivered_content("#{@server.url}/bytes")
    assert content.binary?
    assert_equal 3, content.bytes
    assert_equal "application/octet-stream", content.content_type

    @fake.stub(:get, "/gone", status: 404, body: { error: "gone", code: "not_found" })
    assert_raises(Overpay::NotFound) { @client.fetch_delivered_content("#{@server.url}/gone") }
    assert_equal order_body("orders_show_delivered"), @client.resolve_delivered(order_body("orders_show_delivered")),
                 "an inline delivery is returned untouched"
  end

  def test_concurrent_requests_fall_back_to_one_off_connections_and_close_drops_the_persistent_one
    @fake.stub(:get, "/api/v1/account", times: 8) { |_r| sleep 0.05; [200, fixture("account_show"), {}] }
    threads = 4.times.map { Thread.new { @client.account.get.account_number } }
    assert_equal ["9876543210987654"] * 4, threads.map(&:value)
    assert_operator @server.accepted, :>=, 2, "a busy kept-alive connection is not waited on"
    @client.close
    @client.account.get
    assert_operator @server.accepted, :>=, 3, "close dropped the kept-alive connection"
  end
end
