# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

module Overpay
  # HTTP over Net::HTTP with one kept-alive connection per client.
  #
  # Net::HTTP opens a fresh TCP (+ TLS) connection per request unless told
  # otherwise; a streaming wait polls several times a second, so the
  # handshakes would add straight to the latency the buyer sees. The cached
  # connection is used under a mutex; a caller that finds it busy gets a
  # one-off connection rather than waiting. Net::HTTP's own retry is off -
  # retries are the client's decision (RetryPolicy), never a silent resend.
  #
  # Anything responding to `call(method, uri, headers, body) → [status,
  # headers, body]` (headers lowercased) can replace it (`Client.new(transport:)`).
  class Transport
    KEEP_ALIVE_TIMEOUT = 2 # seconds; Net::HTTP's default, made explicit

    attr_reader :timeout, :open_timeout

    def initialize(timeout: 30, open_timeout: 5, user_agent: nil, ca_file: nil, verify_ssl: true)
      @timeout = timeout
      @open_timeout = open_timeout
      @user_agent = user_agent
      @ca_file = ca_file
      @verify_ssl = verify_ssl
      @mutex = Mutex.new
      @persistent = nil
      @persistent_key = nil
    end

    # Send one request. `uri` is a URI; `body` the exact bytes or nil.
    def call(method, uri, headers, body)
      request = Net::HTTPGenericRequest.new(method, !body.nil?, true, uri.request_uri)
      headers.each { |k, v| request[k] = v }
      request["User-Agent"] = @user_agent if @user_agent && !request["User-Agent"]
      request.body = body if body

      response = with_connection(uri) { |http| http.request(request) }
      response_headers = {}
      response.each_header { |k, v| response_headers[k.downcase] = v }
      [response.code.to_i, response_headers, response.body.to_s]
    rescue Net::OpenTimeout, Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH,
           SocketError, OpenSSL::SSL::SSLError => e
      raise TransportError.new("#{e.class}: #{e.message}", cause: e, ambiguous: false)
    rescue Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, Errno::ECONNRESET, Errno::EPIPE,
           Net::HTTPBadResponse, Net::ProtocolError => e
      raise TransportError.new("#{e.class}: #{e.message}", cause: e, ambiguous: true)
    end

    def close
      @mutex.synchronize { drop_persistent! }
    end

    private

    def with_connection(uri)
      if @mutex.try_lock
        begin
          yield persistent(uri)
        rescue StandardError
          drop_persistent!
          raise
        ensure
          @mutex.unlock
        end
      else
        http = build(uri)
        begin
          http.start { yield http }
        ensure
          http.finish if http.started?
        end
      end
    end

    def persistent(uri)
      key = [uri.scheme, uri.host, uri.port]
      if @persistent && @persistent_key == key
        @persistent.start unless @persistent.started?
        return @persistent
      end

      drop_persistent!
      @persistent_key = key
      @persistent = build(uri)
      @persistent.keep_alive_timeout = KEEP_ALIVE_TIMEOUT
      @persistent.start
      @persistent
    end

    def build(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @timeout
      http.write_timeout = @timeout if http.respond_to?(:write_timeout=)
      http.max_retries = 0 if http.respond_to?(:max_retries=)
      if http.use_ssl?
        http.verify_mode = @verify_ssl ? OpenSSL::SSL::VERIFY_PEER : OpenSSL::SSL::VERIFY_NONE
        http.ca_file = @ca_file if @ca_file
      end
      http
    end

    def drop_persistent!
      @persistent&.finish if @persistent&.started?
    rescue IOError, SystemCallError
      nil
    ensure
      @persistent = nil
      @persistent_key = nil
    end
  end
end
