# frozen_string_literal: true

# Test support for code that uses this gem: a fake marketplace that answers
# every buyer operation from the contract fixtures the real marketplace's
# tests pin, served over a real socket so the whole transport is exercised.
#
#   require "overpay/testing"
#   fake = Overpay::Testing::FakeOverpay.new
#   server = Overpay::Testing::Server.start(fake)
#   client = Overpay::Client.new(base_url: server.url, token: "t")
#   fake.stub(:get, "/api/v1/orders/abc", status: 200, body: { data: { ... } })
#   ...
#   server.stop
#
# FakeOverpay is a Rack-compatible app (`call(env)`), so it also mounts in
# any Rack test harness; Server is a minimal HTTP/1.1 server with no
# dependencies beyond the standard library.

require "json"
require "socket"
require "uri"
require "stringio"

module Overpay
  module Testing
    FIXTURE_DIR = File.expand_path("../../spec/fixtures", __dir__)

    # The contract fixtures, by stem (`orders_show_partial`), parsed.
    def self.fixture(stem)
      JSON.parse(File.read(File.join(FIXTURE_DIR, "#{stem}.json"), encoding: "UTF-8"))
    end

    # `{ "orders_show_partial.json" => { "operation" => "getOrder", "status" => 200 }, ... }`
    def self.fixture_index
      JSON.parse(File.read(File.join(FIXTURE_DIR, "index.json"), encoding: "UTF-8"))
    end

    # One request the fake received.
    Received = Struct.new(:method, :path, :query, :headers, :body, keyword_init: true) do
      def json
        body.nil? || body.empty? ? nil : JSON.parse(body)
      end

      def header(name)
        headers[name.downcase]
      end
    end

    # A fake marketplace. Unstubbed buyer operations answer with the
    # canonical fixture for their success status (chosen by operationId,
    # matched by method and path template); `stub` overrides a method +
    # path with a fixed answer, or a block `(received) -> [status, body,
    # headers]`, consumed in order when several are stubbed for one route.
    class FakeOverpay
      DEFAULT_FIXTURES = {
        "listListings" => "listings_index", "getListing" => "listings_show_variants", "getSeller" => "sellers_show",
        "listOrders" => "orders_index", "createOrder" => "orders_create_paid", "getOrder" => "orders_show_delivered",
        "createSpendAuthorization" => "spend_authorization_create", "getSpendAuthorization" => "spend_authorization_show",
        "closeSpendAuthorization" => "spend_authorization_close", "listMerchantCredits" => "merchant_credits_index",
        "listMerchantCreditTransactions" => "merchant_credit_transactions", "loadCoreCredits" => "merchant_credits_load",
        "getMerchantCreditBalance" => "merchant_credits_show", "purchaseMerchantCredits" => "merchant_credit_purchase",
        "redeemMerchantCredits" => "merchant_credits_redeem", "getAccount" => "account_show",
        "registerBuyer" => "buyer_register", "createWebSession" => "web_session", "getOAuthMetadata" => "oauth_metadata",
        "registerOAuthClient" => "oauth_client", "exchangeOAuthToken" => "oauth_token",
        "acceptQuote" => "orders_accept_quote", "declineQuote" => "orders_show_quote_declined",
        "updateCheckout" => "orders_checkout"
      }.freeze

      attr_reader :requests

      def initialize
        @requests = []
        @stubs = Hash.new { |h, k| h[k] = [] }
        @mutex = Mutex.new
      end

      # Answer `method path` with `status` + `body` (a Hash, serialised as
      # JSON, or a String sent as is) + `headers`; or with the block's
      # `[status, body, headers]`. `times:` repeats the answer. Stubs for one
      # route answer in the order they were added, each once, the newest
      # staying for every request after it.
      def stub(method, path, status: 200, body: nil, headers: {}, times: 1, &block)
        answer = block || ->(_received) { [status, body, headers] }
        @mutex.synchronize { times.times { @stubs[[method.to_s.upcase, path]] << [answer, false] } }
        self
      end

      def clear
        @mutex.synchronize do
          @requests.clear
          @stubs.clear
        end
      end

      def last_request
        @requests.last
      end

      # Rack entry point.
      def call(env)
        received = Received.new(method: env["REQUEST_METHOD"], path: env["PATH_INFO"],
                                query: URI.decode_www_form(env["QUERY_STRING"].to_s).to_h,
                                headers: rack_headers(env), body: env["rack.input"]&.read)
        @mutex.synchronize { @requests << received }
        status, body, headers = answer(received)
        body = JSON.generate(body) unless body.is_a?(String) || body.nil?
        headers = { "content-type" => "application/json" }.merge(headers.transform_keys(&:downcase))
        [status, headers, [body.to_s]]
      end

      private

      def answer(received)
        key = [received.method, received.path]
        stub = @mutex.synchronize do
          list = @stubs[key]
          list.shift while list.size > 1 && list.first[1]
          entry = list.first
          entry[1] = true if entry
          entry&.first
        end
        return stub.call(received) if stub

        operation = Overpay::OPERATIONS.values.find do |op|
          op.method == received.method && path_matches?(op.path, received.path)
        end
        return [404, { "error" => "no route for #{received.method} #{received.path}", "code" => "not_found" }, {}] unless operation

        stem = DEFAULT_FIXTURES[operation.id]
        return [500, { "error" => "no default fixture for #{operation.id}", "code" => "upstream_error" }, {}] unless stem
        unless File.exist?(File.join(FIXTURE_DIR, "#{stem}.json"))
          return [500, { "error" => "fixture #{stem} missing", "code" => "upstream_error" }, {}]
        end

        entry = Testing.fixture_index["#{stem}.json"]
        [entry ? entry["status"] : 200, Testing.fixture(stem), {}]
      end

      def path_matches?(template, path)
        pattern = Regexp.new("\\A" + template.gsub(/\{[^}]+\}/, "[^/]+") + "\\z")
        pattern.match?(path)
      end

      def rack_headers(env)
        headers = {}
        env.each do |k, v|
          next unless k.start_with?("HTTP_") || %w[CONTENT_TYPE CONTENT_LENGTH].include?(k)

          headers[k.delete_prefix("HTTP_").downcase.tr("_", "-")] = v
        end
        headers
      end
    end

    # A minimal HTTP/1.1 server for a Rack-style app, on a loopback port:
    # keep-alive, Content-Length bodies, one thread per connection. Enough
    # to drive a client through a real socket in tests.
    class Server
      attr_reader :port, :app

      # Connections accepted so far (keep-alive reuse keeps it low).
      attr_reader :accepted

      def self.start(app, host: "127.0.0.1")
        new(app, host: host).tap(&:start)
      end

      def initialize(app, host: "127.0.0.1")
        @app = app
        @host = host
        @socket = nil
        @thread = nil
        @connections = []
        @accepted = 0
        @mutex = Mutex.new
      end

      def url
        "http://#{@host}:#{port}"
      end

      def start
        @socket = TCPServer.new(@host, 0)
        @port = @socket.addr[1]
        @thread = Thread.new { accept_loop }
        @thread.abort_on_exception = false
        self
      end

      def stop
        @socket&.close
        @mutex.synchronize { @connections.each { |c| c.close rescue nil } }
        @thread&.join(2)
      end

      private

      def accept_loop
        loop do
          conn = @socket.accept
          @mutex.synchronize do
            @connections << conn
            @accepted += 1
          end
          Thread.new { serve(conn) }
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def serve(conn)
        loop do
          request_line = conn.gets
          break if request_line.nil?

          method, target, = request_line.split(" ", 3)
          headers = {}
          while (line = conn.gets) && line != "\r\n" && line != "\n"
            name, value = line.split(":", 2)
            headers[name.strip.downcase] = value.to_s.strip
          end
          body = headers["content-length"] ? conn.read(headers["content-length"].to_i) : ""
          path, query = target.split("?", 2)
          env = {
            "REQUEST_METHOD" => method, "PATH_INFO" => path, "QUERY_STRING" => query.to_s,
            "rack.input" => StringIO.new(body), "CONTENT_TYPE" => headers["content-type"],
            "CONTENT_LENGTH" => headers["content-length"]
          }
          headers.each { |k, v| env["HTTP_#{k.upcase.tr('-', '_')}"] = v }
          status, response_headers, chunks = @app.call(env)
          payload = chunks.join
          close = headers["connection"].to_s.casecmp("close").zero?
          out = +"HTTP/1.1 #{status} #{reason(status)}\r\n"
          response_headers.each { |k, v| out << "#{k}: #{v}\r\n" }
          out << "Content-Length: #{payload.bytesize}\r\n"
          out << "Connection: #{close ? 'close' : 'keep-alive'}\r\n\r\n"
          conn.write(out)
          conn.write(payload)
          break if close
        end
      rescue IOError, SystemCallError
        nil
      ensure
        conn.close rescue nil
        @mutex.synchronize { @connections.delete(conn) }
      end

      def reason(status)
        { 200 => "OK", 201 => "Created", 204 => "No Content", 301 => "Moved Permanently", 302 => "Found",
          400 => "Bad Request", 401 => "Unauthorized", 402 => "Payment Required", 403 => "Forbidden",
          404 => "Not Found", 409 => "Conflict", 422 => "Unprocessable Entity", 429 => "Too Many Requests",
          500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable",
          504 => "Gateway Timeout" }.fetch(status, "Status")
      end
    end
  end
end
