# frozen_string_literal: true

module Overpay
  # When to retry a request that failed in a way that may be transient.
  #
  # Only requests that are safe to repeat are retried: GETs, and POSTs that
  # carry an idempotency key (the API replays the first response to a
  # repeat). GETs are retried on connection errors, timeouts, and 429, 502,
  # 503 and 504 responses. A POST is by default retried only when it
  # certainly wasn't acted on - a connection that never opened, 429, 503 -
  # because against a server that doesn't honor `Idempotency-Key` a repeat
  # after a timeout, 502 or 504 could act twice; see
  # `Client.new(retry_ambiguous_writes:)`. A keyed POST told that its first
  # attempt is still running (409 `idempotency_request_in_progress`) is
  # asked again: the server replays that attempt's response. Delays grow
  # exponentially with full jitter, and a `Retry-After` header (in seconds)
  # is honored up to `max_delay`.
  class RetryPolicy
    attr_reader :max_attempts, :base_delay, :max_delay

    # `max_attempts` in all (1 disables retries), waiting from `base_delay`
    # seconds, doubling, up to `max_delay` seconds between attempts.
    def initialize(max_attempts: 3, base_delay: 0.25, max_delay: 5.0, rng: Random.new)
      @max_attempts = [max_attempts.to_i, 1].max
      @base_delay = base_delay.to_f
      @max_delay = max_delay.to_f
      @rng = rng
    end

    # Three attempts, 250 ms base delay, at most 5 s between attempts.
    def self.default
      new
    end

    # One attempt; never retry.
    def self.none
      new(max_attempts: 1, base_delay: 0, max_delay: 0)
    end

    def retries?
      max_attempts > 1
    end

    # Seconds to wait after `attempt` (1-based) failed.
    def delay(attempt, retry_after = nil)
      return [retry_after.to_f, max_delay].min if retry_after

      exp = [base_delay * (2**[attempt - 1, 16].min), max_delay].min
      exp.positive? ? @rng.rand * exp : 0.0
    end
  end
end
