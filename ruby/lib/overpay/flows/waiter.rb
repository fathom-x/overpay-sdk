# frozen_string_literal: true

module Overpay
  module Flows
    # One poll of a wait. `state` is :pending while the order is in flight,
    # then :done (the goal was reached - which includes the order failing:
    # read `order.fulfillment_status`) or :timed_out (the order may still
    # finish later). `delta` is the streaming seller's output that is new
    # since the previous poll; `streamed` the bytes handed out so far
    # (`delta` included).
    WaitEvent = Data.define(:state, :order, :elapsed, :delta, :partial_seq, :streamed) do
      def pending?
        state == :pending
      end

      def done?
        state == :done
      end

      def timed_out?
        state == :timed_out
      end

      # The raw snapshot, enveloped (`{"data": {...}}`).
      def snapshot
        { "data" => order.raw }
      end
    end

    # Turns successive `partial_content` buffers into the new text in each.
    #
    # The buffer is an append-only prefix, so the new text is whatever sits
    # past the offset last handed out. Two cases break that and both
    # resynchronize rather than emitting garbage: the buffer shrinking (the
    # marketplace clears it on delivery) and the offset landing
    # mid-character (the buffer is capped on a character boundary, which
    # can move it).
    class PartialTracker
      attr_reader :sent

      def initialize
        @sent = 0
      end

      # The part of `partial` not yet handed out, advancing past it.
      def advance(partial)
        return nil if partial.nil?

        partial = partial.to_s
        if partial.bytesize <= @sent || !char_boundary?(partial, @sent)
          @sent = partial.bytesize
          return nil
        end
        delta = partial.byteslice(@sent..)
        @sent = partial.bytesize
        delta
      end

      private

      def char_boundary?(text, offset)
        head = text.byteslice(0, offset)
        tail = text.byteslice(offset..)
        head.valid_encoding? && tail.valid_encoding?
      end
    end

    # The last streaming buffer the server sent, for the polls where it
    # left the buffer out as unchanged (`since_seq` matched its `partial_seq`).
    class PartialBuffer
      def initialize
        @held = nil
      end

      # Remember the buffer `data` carries, or fill in the one it omits.
      def fill(data)
        seq = data["partial_seq"]
        if seq.nil?
          # Delivered (or never streamed): the buffer is gone.
          @held = nil
          return data
        end
        if data.key?("partial_content") && !data["partial_content"].nil?
          @held = [seq, data["partial_content"]]
        elsif @held && @held[0] == seq
          data["partial_content"] = @held[1]
        end
        data
      end

      def text
        @held&.last
      end
    end

    # Polls an order until it finishes, yielding a WaitEvent per poll:
    # :pending while it is in flight, then one :done or :timed_out. Every
    # event carries the output a streaming seller added since the previous
    # poll - the last one included, so a final flush is never lost.
    #
    # The poll interval runs start-to-start, so a slow request doesn't add
    # its own time on top of it. Each poll after the first is conditional on
    # the last `partial_seq` seen (`since_seq`): the marketplace leaves an
    # unchanged streaming buffer out of the response, so a long reply isn't
    # re-downloaded on every poll. The waiter keeps the last buffer it got
    # and puts it back, so every event's order carries the output so far.
    #
    #   client.wait(order_id) { |event| print event.delta if event.delta }
    #
    class Waiter
      include Enumerable

      attr_reader :order_id, :poll, :timeout, :goal

      # `until:` is :terminal (delivered, failed, cancelled or rejected) or a
      # fulfillment status - reaching any terminal one ends the wait too.
      # `stop_before_overrun: true` times out as soon as another poll
      # wouldn't fit in the timeout, rather than once the timeout has passed.
      def initialize(client, order_id, poll: 1.0, timeout: 120.0, until: :terminal, resolve_delivered: true,
                     stop_before_overrun: false, auth: nil)
        @client = client
        @order_id = order_id
        @poll = poll.to_f
        @timeout = timeout.to_f
        @goal = binding.local_variable_get(:until)
        @resolve_delivered = resolve_delivered
        @deadline = stop_before_overrun ? :before_next_poll : :elapsed
        @auth = auth
      end

      # Yield each poll's event; ends after :done or :timed_out. Without a
      # block, an Enumerator.
      def each
        return to_enum(:each) unless block_given?

        start = now
        tracker = PartialTracker.new
        buffer = PartialBuffer.new
        seen_seq = nil
        last_poll = nil
        loop do
          @client.sleeper.call(next_sleep(now - last_poll, now - start)) if last_poll
          last_poll = now
          order = fetch(seen_seq)
          buffer.fill(order.raw)
          elapsed = now - start
          state =
            if reached?(order.fulfillment_status) then :done
            elsif out_of_time?(elapsed) then :timed_out
            else :pending
            end
          seen_seq = order.partial_seq unless order.partial_seq.nil?
          delta = tracker.advance(order.partial_content)
          yield WaitEvent.new(state: state, order: order, elapsed: elapsed, delta: delta,
                              partial_seq: order.partial_seq, streamed: tracker.sent)
          return if state != :pending
        end
      end

      # Wait to the end and return the final event (:done or :timed_out).
      def wait(&block)
        last = nil
        each do |event|
          block&.call(event)
          last = event
        end
        last
      end

      # Stream the seller's output: yield each delta as it arrives, then -
      # once delivered - the part of `delivered_content` the preview buffer
      # didn't carry (it is capped at 32 KB and cleared on delivery, and a
      # fast seller may deliver before streaming anything). Returns the
      # final event. Assumes the deliverable is the streamed text itself.
      def stream
        final = wait do |event|
          yield event.delta if event.delta
        end
        if final.done? && final.order.delivered?
          rest = Waiter.catch_up(final.order.delivered_content, final.streamed)
          yield rest if rest
        end
        final
      end

      # The part of a delivered text past the `streamed` bytes already
      # handed out, or nil.
      def self.catch_up(delivered_text, streamed)
        return nil unless delivered_text.is_a?(String)
        return nil if streamed >= delivered_text.bytesize

        head = delivered_text.byteslice(0, streamed)
        rest = delivered_text.byteslice(streamed..)
        head.valid_encoding? && rest.valid_encoding? ? rest : nil
      end

      private

      def fetch(since_seq)
        order = @client.orders.get(order_id, since_seq: since_seq, auth: @auth)
        order = @client.resolve_delivered(order) if @resolve_delivered
        order
      end

      def reached?(status)
        return false if status.nil?

        FulfillmentStatus::TERMINAL.include?(status) || (goal != :terminal && goal.to_s == status)
      end

      # Whether a poll answered `elapsed` into the wait ends it as timed out.
      def out_of_time?(elapsed)
        case @deadline
        when :elapsed then elapsed >= timeout
        else elapsed + poll >= timeout
        end
      end

      # How long to wait before the next poll: the rest of the interval
      # since the previous one started - cut short, when the wait times out
      # once its time has passed, so the last poll lands on the timeout.
      def next_sleep(since_last_poll, elapsed)
        rest = [poll - since_last_poll, 0.0].max
        case @deadline
        when :elapsed then [rest, [timeout - elapsed, 0.0].max].min
        else rest
        end
      end

      def now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
