# frozen_string_literal: true

require "test_helper"
require "digest"

class ClientTest < Minitest::Test
  include Overpay::TestSupport

  def setup
    start_fake
  end

  def teardown
    stop_fake
  end

  def test_public_endpoints_send_no_auth_and_keep_the_connection_alive
    page = @client.listings.list
    listing = @client.listings.get(page.data.first.id)
    assert_equal "Buy Anything with a Personal Shopper", page.data.first.title
    assert_equal "Metered inference", listing.title
    assert_nil @fake.requests[0].header("authorization")
    assert_equal "application/json", @fake.requests[0].header("accept")
    assert_equal 1, @server.accepted, "both requests rode one connection"
  end

  def test_bearer_auth_and_envelopes
    account = @client.account.get
    assert_equal "Bearer test-token", @fake.last_request.header("authorization")
    assert_equal "9876543210987654", account.account_number
    assert_equal 200, account.response.status
    credits = @client.credits.list
    assert_equal 2, credits.size
    assert_equal BigDecimal("700"), credits.first.balance_cents
  end

  def test_order_create_sends_the_documented_body_and_an_idempotency_key
    created = @client.orders.create(listing_id: "L1", buyer_note: { prompt: "hi" }, variant: "cheap",
                                    authorization_cents: 49.2, client_session_id: "conv-1")
    request = @fake.last_request
    assert_equal({ "listing_id" => "L1", "buyer_note" => '{"prompt":"hi"}', "variant" => "cheap",
                   "pay" => "merchant_credits", "authorization_cents" => 50, "client_session_id" => "conv-1" }, request.json)
    assert_match(/\A[0-9a-f]{32}\z/, request.header("idempotency-key"))
    assert_equal "application/json", request.header("content-type")
    assert created.paid?
    assert_equal BigDecimal("50"), created.payment.amount_redeemed_cents
  end

  def test_since_seq_rides_along_and_an_omitted_buffer_is_not_invented
    @fake.stub(:get, "/api/v1/orders/o1", body: order_body(partial_content: nil))
    order = @client.orders.get("o1", since_seq: 1)
    assert_equal({ "since_seq" => "1" }, @fake.last_request.query)
    assert_nil order.partial_content
    assert_equal 1, order.partial_seq
  end

  def test_gets_retry_on_503_and_honor_retry_after
    @fake.stub(:get, "/api/v1/account", status: 503, body: { error: "down", code: "upstream_unavailable" },
                                        headers: { "Retry-After" => "1" })
    @fake.stub(:get, "/api/v1/account", body: fixture("account_show"))
    account = @client.account.get
    assert_equal "9876543210987654", account.account_number
    assert_equal 2, @fake.requests.size
    assert_equal [0.05], @sleeps, "Retry-After capped at max_delay"
  end

  def test_a_get_that_keeps_failing_raises_the_last_error
    @fake.stub(:get, "/api/v1/account", status: 429, body: { error: "slow down", code: "conflict" }, times: 5)
    error = assert_raises(Overpay::ApiError) { @client.account.get }
    assert_equal 429, error.status
    assert_equal 3, @fake.requests.size
  end

  def test_a_keyed_write_is_not_repeated_after_a_502_unless_opted_in
    @fake.stub(:post, "/api/v1/orders", status: 502, body: "<html><title>Bad Gateway</title></html>", times: 3)
    error = assert_raises(Overpay::ApiError) { @client.orders.create(listing_id: "L1") }
    assert_equal 1, @fake.requests.size
    assert_match(/web page instead of a reply \("Bad Gateway"\)/, error.message)

    @fake.clear
    @fake.stub(:post, "/api/v1/orders", status: 502, body: "", times: 1)
    @fake.stub(:post, "/api/v1/orders", status: 201, body: fixture("orders_create_unpaid"))
    opted = Overpay::Client.new(base_url: @server.url, token: "t", retry_ambiguous_writes: true,
                                retry_policy: Overpay::RetryPolicy.new(max_attempts: 3, base_delay: 0.001, max_delay: 0.001),
                                sleeper: ->(_) {})
    created = opted.orders.create(listing_id: "L1")
    refute created.paid?
    assert_equal 2, @fake.requests.size
    assert_equal @fake.requests[0].header("idempotency-key"), @fake.requests[1].header("idempotency-key")
    opted.close
  end

  def test_a_keyed_write_without_automatic_keys_never_retries
    bare = Overpay::Client.new(base_url: @server.url, token: "t", idempotency_keys: false, sleeper: ->(_) {})
    @fake.stub(:post, "/api/v1/orders", status: 503, body: { error: "x", code: "upstream_unavailable" }, times: 3)
    assert_raises(Overpay::ApiError) { bare.orders.create(listing_id: "L1") }
    assert_equal 1, @fake.requests.size
    assert_nil @fake.last_request.header("idempotency-key")
    bare.close
  end

  def test_a_keyed_write_still_in_progress_is_asked_again_and_replays
    @fake.stub(:post, "/api/v1/orders", status: 409, body: { error: "running", code: "idempotency_request_in_progress" })
    @fake.stub(:post, "/api/v1/orders", status: 201, body: fixture("orders_create_paid"),
                                        headers: { "Idempotent-Replayed" => "true" })
    created = @client.orders.create(listing_id: "L1")
    assert created.paid?
    assert created.response.replayed?
    assert_equal 2, @fake.requests.size
  end

  def test_other_409s_raise_at_once
    @fake.stub(:post, "/api/v1/orders", status: 409, body: { error: "dup", code: "duplicate_settlement" })
    error = assert_raises(Overpay::ApiError) { @client.orders.create(listing_id: "L1") }
    assert_equal "duplicate_settlement", error.code
    assert_equal 1, @fake.requests.size
  end

  def test_connection_refused_is_a_transport_error_and_retried_for_reads
    dead = Overpay::Client.new(base_url: "http://127.0.0.1:1", token: "t", open_timeout: 0.2,
                               retry_policy: Overpay::RetryPolicy.new(max_attempts: 2, base_delay: 0.001, max_delay: 0.001),
                               sleeper: ->(s) { @sleeps << s })
    error = assert_raises(Overpay::TransportError) { dead.account.get }
    refute error.ambiguous?
    assert_equal 1, @sleeps.size, "one retry between two attempts"
  end

  def test_api_errors_carry_status_code_and_details
    @fake.stub(:post, "/api/v1/orders", status: 402, body: fixture("error_insufficient_credits"))
    error = assert_raises(Overpay::InsufficientCredits) { @client.orders.create(listing_id: "L1", authorization_cents: 50) }
    assert_equal 402, error.status
    assert_equal BigDecimal("50"), error.detail_cents("authorization_cents")
  end

  def test_nip98_signs_every_attempt_over_the_final_url_and_the_exact_body
    signer = Overpay::Nip98::Signer.new("11" * 32, backend: Overpay::TestSupport::FakeSchnorr.new)
    client = Overpay::Client.new(base_url: @server.url, token: "t", signer: signer,
                                 retry_policy: Overpay::RetryPolicy.new(max_attempts: 2, base_delay: 0.001, max_delay: 0.001),
                                 sleeper: ->(_) {})
    @fake.stub(:post, "/api/v1/orders", status: 503, body: { error: "x", code: "upstream_unavailable" })
    @fake.stub(:post, "/api/v1/orders", status: 201, body: fixture("orders_create_paid"))
    client.orders.create(listing_id: "L1", buyer_note: "exact bytes")
    assert_equal 2, @fake.requests.size
    @fake.requests.each do |request|
      assert_equal "Bearer t", request.header("authorization")
      event = JSON.parse(Base64.strict_decode64(request.header("x-nostr-signature").delete_prefix("Nostr ")))
      tags = event["tags"].to_h
      assert_equal "#{@server.url}/api/v1/orders", tags["u"]
      assert_equal "POST", tags["method"]
      assert_equal Digest::SHA256.hexdigest(request.body), tags["payload"]
      assert_equal 27235, event["kind"]
      assert_equal signer.pubkey, event["pubkey"]
    end

    client.listings.list
    assert_nil @fake.last_request.header("x-nostr-signature"), "public endpoints are unsigned"
    client.account.get(auth: Overpay::Auth.nip98(signer))
    assert_match(/\ANostr /, @fake.last_request.header("authorization"))
    assert_nil JSON.parse(Base64.strict_decode64(@fake.last_request.header("authorization").delete_prefix("Nostr ")))["tags"].to_h["payload"],
               "a GET carries no payload tag"
    client.close
  end

  def test_requests_outside_the_typed_resources
    @fake.stub(:get, "/api/v1/something", body: { data: { "x" => 1 } })
    response = @client.execute(Overpay::Request.get("/api/v1/something", query: { a: 1, b: nil, ids: %w[p q] }))
    assert_equal({ "x" => 1 }, response.data)
    assert_equal({ "a" => "1", "ids[]" => "q" }, @fake.last_request.query)
    assert_equal "/api/v1/something", @fake.last_request.path
  end

  def test_base_url_normalisation_and_public_url
    client = Overpay::Client.new(base_url: "http://api.example:80/", public_url: "https://overpay.example/")
    assert_equal "http://api.example", client.base_url
    assert_equal "https://overpay.example", client.public_url
    assert_equal "https://overpay.example/orders/1", client.to_public_url("http://api.example/orders/1")
    assert_equal "http://elsewhere/x", client.to_public_url("http://elsewhere/x")
    assert_equal "https://overpay.example/oauth/authorize?a=1", client.public_join("/oauth/authorize?a=1")
    assert_raises(ArgumentError) { Overpay::Client.new(base_url: "not a url") }
  end

  def test_seller_and_credit_calls
    seller = @client.sellers.get("alice-shop")
    assert_equal "alice-shop", seller.slug
    assert_equal 2, seller.wallets.size
    balance = @client.credits.balance("alice shop")
    assert_equal "/api/v1/merchant_credits/alice%20shop", @fake.last_request.path
    assert_equal BigDecimal("700"), balance.balance_cents
    load = @client.credits.load(amount_cents: 1000)
    assert_equal({ "amount_cents" => 1000 }, @fake.last_request.json)
    assert_match(/\Alntb/, load.bolt11)
    page = @client.credits.transactions(since: Time.utc(2026, 1, 1), limit: 10)
    assert_equal "2026-01-01T00:00:00Z", @fake.last_request.query["since"]
    assert page.data.first.spend?
    redemption = @client.credits.redeem("alice-shop", order_id: "o1")
    assert redemption.settled?
    purchase = @client.credits.purchase("alice-shop", amount_cents: 500)
    assert_equal "0x1111111111111111111111111111111111111111", purchase.payment_address
  end

  def test_spend_authorization_calls_and_buyer_calls
    auth = @client.spend_authorizations.create(listing_id: "L1", cap_cents: 500, expires_in_seconds: 60)
    assert_equal({ "listing_id" => "L1", "cap_cents" => 500, "expires_in_seconds" => 60 }, @fake.last_request.json)
    assert auth.open?
    assert_equal BigDecimal("500"), @client.spend_authorizations.get(auth.id).remaining_cents
    assert_equal "closed", @client.spend_authorizations.close(auth.id).status
    session = @client.buyer.web_session
    assert_match(/token_login/, session.login_url)
    registration = @client.buyer.register(username: "bob", auth: Overpay::Auth.nip98(
      Overpay::Nip98::Signer.new("22" * 32, backend: Overpay::TestSupport::FakeSchnorr.new)
    ))
    assert_equal({ "username" => "bob" }, @fake.last_request.json)
    assert_match(/\ANostr /, @fake.last_request.header("authorization"))
    refute_includes registration.inspect, registration.token
  end

  def test_oauth_calls
    metadata = @client.oauth.metadata
    assert_equal ["S256"], metadata.code_challenge_methods_supported
    registered = @client.oauth.register_client(client_name: "app", redirect_uris: ["http://127.0.0.1:1/cb"], scope: "wallet")
    assert_equal fixture("oauth_client")["client_id"], registered.client_id
    assert_equal "wallet", @fake.last_request.json["scope"]
    token = @client.oauth.exchange_code(code: "c", redirect_uri: "http://127.0.0.1:1/cb", code_verifier: "v", client_id: "id")
    assert_equal "application/x-www-form-urlencoded", @fake.last_request.header("content-type")
    assert_equal "grant_type=authorization_code&code=c&redirect_uri=http%3A%2F%2F127.0.0.1%3A1%2Fcb&code_verifier=v&client_id=id",
                 @fake.last_request.body
    assert_equal "test-token-placeholder", token.access_token
  end
end
