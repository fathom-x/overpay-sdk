# frozen_string_literal: true

require "test_helper"

class WaiterTest < Minitest::Test
  include Overpay::TestSupport

  def setup
    start_fake
  end

  def teardown
    stop_fake
  end

  def test_tracker_emits_only_new_text_and_resyncs
    t = Overpay::Flows::PartialTracker.new
    assert_equal "Hel", t.advance("Hel")
    assert_equal "lo", t.advance("Hello")
    assert_nil t.advance("Hello")
    assert_nil t.advance("")
    assert_equal 0, t.sent
    assert_nil t.advance(nil)
  end

  def test_tracker_resyncs_off_a_char_boundary
    t = Overpay::Flows::PartialTracker.new
    t.advance("\xC3") # one byte handed out: half of "é"
    assert_nil t.advance("é and more")
    assert_equal "é and more".bytesize, t.sent
  end

  def test_catch_up_hands_out_the_rest_of_a_delivered_text
    assert_equal "world", Overpay::Flows::Waiter.catch_up("hello world", 6)
    assert_nil Overpay::Flows::Waiter.catch_up("hello", 5)
    assert_nil Overpay::Flows::Waiter.catch_up(nil, 0)
    assert_nil Overpay::Flows::Waiter.catch_up("é!", 1)
  end

  def test_streams_deltas_fills_omitted_buffers_and_ends_on_delivery
    polls = [
      order_body(partial_seq: 1, partial_content: "Hel"),
      order_body(partial_seq: 1, partial_content: nil), # unchanged: omitted by the server
      order_body(partial_seq: 2, partial_content: "Hello, wor"),
      order_body(fulfillment_status: "delivered", partial_seq: nil, partial_content: nil,
                 delivered_content: "Hello, world!", delivered_at: "2026-10-02T21:00:40Z")
    ]
    @fake.stub(:get, "/api/v1/orders/o1") { [200, polls.shift, {}] }
    events = @client.wait("o1", poll: 0.5).to_a
    assert_equal %i[pending pending pending done], events.map(&:state)
    assert_equal ["Hel", nil, "lo, wor", nil], events.map(&:delta)
    assert_equal "Hel", events[1].order.partial_content, "the held buffer is put back"
    assert_equal [nil, 1, 1, 2], @fake.requests.map { |r| r.query["since_seq"]&.to_i }
    assert_equal "Hello, world!", events.last.order.delivered_content
    assert_equal 10, events.last.streamed
    assert_equal 3, @sleeps.size
    assert @sleeps.all? { |s| s <= 0.5 }
  end

  def test_stream_catches_up_the_part_the_preview_missed
    polls = [
      order_body(partial_seq: 1, partial_content: "Hello"),
      order_body(fulfillment_status: "delivered", partial_seq: nil, partial_content: nil, delivered_content: "Hello, world!")
    ]
    @fake.stub(:get, "/api/v1/orders/o1") { [200, polls.shift, {}] }
    chunks = []
    final = @client.stream("o1", poll: 0.01) { |delta| chunks << delta }
    assert_equal ["Hello", ", world!"], chunks
    assert final.done?
  end

  def test_a_shrunken_buffer_resyncs_instead_of_emitting_garbage
    polls = [
      order_body(partial_seq: 1, partial_content: "long preview text"),
      order_body(partial_seq: 2, partial_content: "short"),
      order_body(fulfillment_status: "failed", partial_seq: nil, partial_content: nil, fulfillment_error: "boom")
    ]
    @fake.stub(:get, "/api/v1/orders/o1") { [200, polls.shift, {}] }
    events = @client.wait("o1", poll: 0.01).to_a
    assert_equal ["long preview text", nil, nil], events.map(&:delta)
    assert events.last.done?
    assert_equal "failed", events.last.order.fulfillment_status
  end

  def test_rejected_is_terminal_and_a_target_status_ends_the_wait
    @fake.stub(:get, "/api/v1/orders/o1", body: fixture("orders_show_rejected"))
    final = @client.wait("o1", poll: 0.01).wait
    assert final.done? && final.order.rejected?

    @fake.stub(:get, "/api/v1/orders/o2", body: order_body(fulfillment_status: "shipping"))
    event = @client.wait("o2", poll: 0.01, until: "shipping").wait
    assert event.done?
    assert_equal 1, @fake.requests.count { |r| r.path.end_with?("o2") }
  end

  def test_times_out_once_its_time_has_passed
    @fake.stub(:get, "/api/v1/orders/o1", body: order_body)
    clock = 0.0
    @client.define_singleton_method(:sleeper) { ->(s) { clock += s } }
    waiter = Overpay::Flows::Waiter.new(@client, "o1", poll: 1.0, timeout: 2.5)
    waiter.define_singleton_method(:now) { clock }
    events = waiter.to_a
    assert_equal %i[pending pending pending timed_out], events.map(&:state)
    assert_equal 2.5, events.last.elapsed
  end

  def test_stop_before_overrun_times_out_when_another_poll_would_not_fit
    @fake.stub(:get, "/api/v1/orders/o1", body: order_body)
    clock = 0.0
    @client.define_singleton_method(:sleeper) { ->(s) { clock += s } }
    waiter = Overpay::Flows::Waiter.new(@client, "o1", poll: 1.0, timeout: 2.5, stop_before_overrun: true)
    waiter.define_singleton_method(:now) { clock }
    events = waiter.to_a
    assert_equal %i[pending pending timed_out], events.map(&:state)
  end

  def test_an_offloaded_deliverable_is_inlined_following_the_redirect
    blob = "#{@server.url}/rails/active_storage/blobs/redirect/abc/result.bin"
    @fake.stub(:get, "/rails/active_storage/blobs/redirect/abc/result.bin", status: 302, body: "",
                                                                             headers: { "Location" => "/storage/abc" })
    @fake.stub(:get, "/storage/abc", status: 200, body: "the whole long reply",
                                     headers: { "Content-Type" => "application/octet-stream" })
    @fake.stub(:get, "/api/v1/orders/o1", body: order_body("orders_show_offloaded", delivered_content_url: blob))
    final = @client.wait("o1", poll: 0.01).wait
    assert_equal "the whole long reply", final.order.delivered_content
    refute final.order.offloaded?
    assert_nil @fake.requests.find { |r| r.path == "/storage/abc" }.header("authorization")
  end

  def test_a_binary_deliverable_stays_a_link
    blob = "#{@server.url}/blob.png"
    @fake.stub(:get, "/blob.png", status: 200, body: "\x89PNG".b, headers: { "Content-Type" => "image/png" })
    order = Overpay::Models::Order.from_body(order_body("orders_show_offloaded", delivered_content_url: blob,
                                                                                delivered_content_type: nil))
    resolved = @client.resolve_delivered(order)
    assert_nil resolved.delivered_content
    assert_equal "image/png", resolved.delivered_content_type
    assert_equal 4, resolved["delivered_content_bytes"]
  end

  def test_a_deliverable_on_another_host_is_refused
    order = Overpay::Models::Order.from_body(order_body("orders_show_offloaded",
                                                        delivered_content_url: "http://elsewhere.example/x"))
    assert_raises(Overpay::DeliveryError) { @client.resolve_delivered(order) }
  end
end
