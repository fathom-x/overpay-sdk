# frozen_string_literal: true

require "securerandom"
require "uri"

module Overpay
  # A client for one Overpay marketplace.
  #
  #   client = Overpay::Client.new(base_url: "https://overpay.example", token: "...")
  #   client.listings.list.each { |l| puts "#{l.title} - #{l.price_usd}" }
  #   paid = client.place_and_pay(listing_id: "...", authorization_cents: 50)
  #   client.wait(paid.order_id).order.delivered_content
  #
  # Resources: `listings`, `sellers`, `orders`, `credits`,
  # `spend_authorizations`, `account`, `buyer`, `oauth`. Flows:
  # `place_and_pay` / `create_unpaid_order` / `pay_with_credits` (Flows::Pay),
  # `wait` (Flows::Waiter), `resolve_delivered` (Flows::Delivered), `wallet`,
  # `spend_session`, `request_quote` / `wait_for_quote` / `checkout`.
  #
  # Thread-safe: one kept-alive connection is shared under a mutex, and a
  # caller that finds it busy uses a one-off connection.
  class Client
    include Flows::Pay
    include Flows::Delivered

    DEFAULT_USER_AGENT = "overpay-ruby/#{VERSION}".freeze

    attr_reader :base_url, :public_url, :auth, :retry_policy, :transport, :sleeper, :logger

    # `token:` (an API token from /account/api_keys, registration or OAuth)
    # and/or `signer:` (a NIP-98 signer, `require "overpay/nip98"`) set the
    # default Auth: Bearer, NIP-98, or both (`bearer_signed`). `public_url:`
    # is the URL browsers use when it differs from the API base (Docker,
    # reverse proxies): browser-facing URLs use it. `retry_ambiguous_writes:`
    # also repeats a keyed write after a timeout, 502 or 504 - safe only
    # against a marketplace that honors `Idempotency-Key`.
    def initialize(base_url:, token: nil, signer: nil, auth: nil, public_url: nil, timeout: 30, open_timeout: 5,
                   retry_policy: RetryPolicy.default, idempotency_keys: true, retry_ambiguous_writes: false,
                   user_agent: DEFAULT_USER_AGENT, transport: nil, sleeper: nil, logger: nil, ca_file: nil)
      @base_url = normalize_url(base_url)
      @public_url = public_url ? normalize_url(public_url) : @base_url
      @auth = auth ? Auth.coerce(auth) : default_auth(token, signer)
      @retry_policy = retry_policy || RetryPolicy.none
      @idempotency_keys = idempotency_keys
      @retry_ambiguous_writes = retry_ambiguous_writes
      @transport = transport || Transport.new(timeout: timeout, open_timeout: open_timeout, user_agent: user_agent,
                                              ca_file: ca_file)
      @sleeper = sleeper || ->(seconds) { sleep(seconds) if seconds.positive? }
      @logger = logger
    end

    # The API base URL without a trailing slash - a stable key to file
    # credentials for this marketplace under.
    def host_key
      base_url.chomp("/")
    end

    def base_uri
      @base_uri ||= URI.parse(base_url)
    end

    def public_uri
      @public_uri ||= URI.parse(public_url)
    end

    # `path` joined onto the public URL.
    def public_join(path)
      URI.join("#{public_url}/", path.to_s.delete_prefix("/")).to_s
    end

    # Rewrite a URL the API returned on the API host to the public host.
    # Other URLs pass through.
    def to_public_url(raw)
      uri = URI.parse(raw.to_s)
      return raw unless public_url != base_url && uri.host == base_uri.host && uri.port == base_uri.port

      "#{public_url}#{uri.request_uri}"
    rescue URI::InvalidURIError
      raw
    end

    # A fresh idempotency key when automatic keys are on.
    def auto_idempotency_key
      @idempotency_keys ? Client.new_idempotency_key : nil
    end

    # A random 128-bit key, hex.
    def self.new_idempotency_key
      SecureRandom.hex(16)
    end

    def listings = @listings ||= Resources::Listings.new(self)
    def sellers = @sellers ||= Resources::Sellers.new(self)
    def orders = @orders ||= Resources::Orders.new(self)
    def credits = @credits ||= Resources::Credits.new(self)
    def spend_authorizations = @spend_authorizations ||= Resources::SpendAuthorizations.new(self)
    def account = @account ||= Resources::Account.new(self)
    def buyer = @buyer ||= Resources::Buyer.new(self)
    def oauth = @oauth ||= Resources::OAuth.new(self)

    # Poll an order until it finishes (Flows::Waiter). With a block, waits to
    # the end yielding each poll's event and returns the final one; without,
    # returns the Waiter to iterate or `stream`.
    def wait(order_id, poll: 1.0, timeout: 120.0, until: :terminal, resolve_delivered: true,
             stop_before_overrun: false, auth: nil, &block)
      waiter = Flows::Waiter.new(self, order_id, poll: poll, timeout: timeout,
                                                  until: binding.local_variable_get(:until),
                                                  resolve_delivered: resolve_delivered,
                                                  stop_before_overrun: stop_before_overrun, auth: auth)
      block ? waiter.wait(&block) : waiter
    end

    # Place an order and stream the seller's output to the block as it
    # arrives, returning the final WaitEvent (see Waiter#stream).
    def stream(order_id, **wait_opts, &block)
      wait(order_id, **wait_opts).stream(&block)
    end

    # The buyer's credit balances and top-ups (Flows::Wallet).
    def wallet(auth: nil)
      Flows::Wallet.new(self, auth: auth)
    end

    # Open a spending cap on a metered listing (Flows::SpendSession).
    def spend_session(listing_id:, cap_cents:, expires_in_seconds: nil, auth: nil)
      Flows::SpendSession.open(self, listing_id: listing_id, cap_cents: cap_cents,
                                     expires_in_seconds: expires_in_seconds, auth: auth)
    end

    # Ask a request_quote listing's seller for a price: an `awaiting_quote`
    # order. Then `wait_for_quote`, `orders.accept_quote` (or `checkout`,
    # which accepts on the way) and `pay_with_credits`.
    def request_quote(listing_id:, buyer_note: nil, quantity: nil, client_session_id: nil, auth: nil)
      orders.create(listing_id: listing_id, buyer_note: buyer_note, quantity: quantity,
                    client_session_id: client_session_id, auth: auth).order
    end

    # Poll a quote request until the seller answers. Returns the quoted
    # order (`quote`, `total_usd_cents`); raises QuoteDeclined when the
    # seller declined; returns the still-waiting order on timeout
    # (`awaiting_quote?`).
    def wait_for_quote(order_id, poll: 5.0, timeout: 600.0, auth: nil)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loop do
        order = orders.get(order_id, auth: auth)
        raise QuoteDeclined, order if order.quote_declined?
        return order unless order.awaiting_quote?

        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        return order if elapsed >= timeout

        sleeper.call([poll, timeout - elapsed].min)
      end
    end

    # Supply checkout data before paying. `shipping_address:` is the common
    # case (`{name:, line1:, city:, ...}`, per the listing's `checkout_schema`);
    # any other fields go in `checkout_data:`.
    def checkout(order_id, shipping_address: nil, checkout_data: {}, auth: nil)
      data = checkout_data.transform_keys(&:to_s)
      data["shipping_address"] = shipping_address unless shipping_address.nil?
      orders.update_checkout(order_id, checkout_data: data, auth: auth)
    end

    # Send `request`, retrying per the RetryPolicy when it is safe to, and
    # return the Response of a 2xx answer. A non-2xx answer raises ApiError
    # (or a subclass for its code); a failed connection, TransportError.
    def execute(request, auth = nil)
      auth = auth.nil? ? self.auth : Auth.coerce(auth)
      uri = url_for(request)
      policy = request.retryable? ? retry_policy : RetryPolicy.none
      # A read may always be repeated; a write only where it certainly
      # wasn't acted on, unless the caller vouches for idempotency.
      ambiguous_ok = request.read? || @retry_ambiguous_writes
      attempt = 1
      loop do
        begin
          status, headers, body = send_once(request, uri, auth)
        rescue TransportError => e
          raise e unless attempt < policy.max_attempts && (!e.ambiguous? || ambiguous_ok)

          log("#{request.method} #{uri} attempt #{attempt} failed: #{e.message}; retrying")
          sleeper.call(policy.delay(attempt))
          attempt += 1
          next
        end

        if attempt < policy.max_attempts && retryable_status?(status, ambiguous_ok)
          sleeper.call(policy.delay(attempt, retry_after(headers)))
          attempt += 1
          next
        end
        # A keyed write whose first attempt is still running on the server
        # (its response was lost on the way back): asking again is safe -
        # the server replays the stored response once that attempt finishes.
        if attempt < policy.max_attempts && status == 409 && request.idempotency_key
          error = ApiError.from_response(status, body)
          raise error unless error.code == ErrorCode::IDEMPOTENCY_REQUEST_IN_PROGRESS

          sleeper.call(policy.delay(attempt, retry_after(headers)))
          attempt += 1
          next
        end
        return read_response(status, headers, body)
      end
    end

    def close
      transport.close if transport.respond_to?(:close)
    end

    private

    def default_auth(token, signer)
      if token && signer then Auth.bearer_signed(token, signer)
      elsif token then Auth.bearer(token)
      elsif signer then Auth.nip98(signer)
      else Auth::NONE
      end
    end

    def normalize_url(url)
      uri = begin
        URI.parse(url.to_s)
      rescue URI::InvalidURIError
        nil
      end
      raise ArgumentError, "base_url must be an http(s) URL: #{url.inspect}" unless uri.is_a?(URI::HTTP)

      # Default ports are dropped and the trailing slash too, so a NIP-98
      # `u` tag matches the URL the server sees.
      uri.port = nil if uri.port == uri.default_port
      uri.path = uri.path.chomp("/")
      uri.to_s
    end

    def url_for(request)
      uri = request.path.match?(%r{\Ahttps?://}) ? URI.parse(request.path) : URI.join("#{base_url}/", request.path.delete_prefix("/"))
      query = request.query_string
      uri.query = [uri.query, query].compact.join("&") if query
      uri
    end

    def send_once(request, uri, auth)
      # The body is serialised once, here: a signature's `payload` tag is
      # the hash of these exact bytes, and these are the bytes sent.
      body, content_type = request.encoded_body
      # Signed per attempt: NIP-98 events expire and must name the exact
      # URL the server sees.
      headers = auth.headers(request.method, uri.to_s, body)
      headers["Accept"] = "application/json" if request.accept_json
      headers["Content-Type"] = content_type if content_type
      headers[Request::IDEMPOTENCY_KEY_HEADER] = request.idempotency_key if request.idempotency_key
      transport.call(request.method, uri, headers, body)
    end

    # 429 and 503 mean the server didn't act; after a 502 or 504 it may have.
    def retryable_status?(status, ambiguous_ok)
      case status
      when 429, 503 then true
      when 502, 504 then ambiguous_ok
      else false
      end
    end

    def retry_after(headers)
      value = headers["retry-after"].to_s.strip
      value.match?(/\A\d+\z/) ? value.to_i : nil
    end

    def read_response(status, headers, body)
      raise ApiError.from_response(status, body) unless (200..299).cover?(status)

      parsed =
        if body.nil? || body.strip.empty?
          nil
        else
          begin
            JSON.parse(body)
          rescue JSON::ParserError => e
            raise JsonError, "response is not valid JSON: #{e.message}"
          end
        end
      Response.new(status: status, headers: headers, body: parsed)
    end

    def log(message)
      logger&.info("[overpay] #{message}")
    end
  end
end
