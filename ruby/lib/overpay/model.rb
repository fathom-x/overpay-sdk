# frozen_string_literal: true

require "time"

module Overpay
  # A typed view over one JSON object the API sent. `raw` is the object
  # exactly as sent - nothing is dropped, and fields this gem doesn't know
  # are reachable through `[]` and `extra` - while the declared accessors
  # convert on read: money to BigDecimal cents (Money.parse), timestamps to
  # Time, nested objects to their models.
  class Model
    attr_reader :raw
    attr_accessor :response

    def initialize(raw, response: nil)
      raise ArgumentError, "#{self.class}: expected a JSON object, got #{raw.class}" unless raw.is_a?(Hash)

      @raw = raw
      @response = response
      @cache = {}
    end

    # Build from a response body: the `data` envelope's payload, or the
    # whole body for types without one.
    def self.from_body(body, response: nil)
      new(envelope? && body.is_a?(Hash) && body.key?("data") ? body["data"] : body, response: response)
    end

    def self.envelope?
      true
    end

    # Types that are the whole body (no `data` envelope).
    def self.whole_body!
      define_singleton_method(:envelope?) { false }
    end

    class << self
      def known_keys
        @known_keys ||= []
      end

      # `{ "json key" => :accessor_name }` for every declared field.
      def accessors
        @accessors ||= {}
      end

      # A plain accessor over `raw[key]`, optionally converted by the block.
      def field(name, key = name.to_s, &convert)
        known_keys << key
        accessors[key] = name
        define_method(name) do
          @cache.fetch(name) do
            value = raw[key]
            @cache[name] = value.nil? || convert.nil? ? value : instance_exec(value, &convert)
          end
        end
      end

      def fields(*names)
        names.each { |n| field(n) }
      end

      def cents(*names)
        names.each { |n| field(n) { |v| Money.parse(v) } }
      end

      def times(*names)
        names.each { |n| field(n) { |v| v.is_a?(String) ? Time.iso8601(v) : v } }
      end

      def booleans(*names)
        names.each do |n|
          field(n)
          define_method(:"#{n}?") { !!public_send(n) }
        end
      end

      def has_one(name, klass, key = name.to_s)
        field(name, key) { |v| v.is_a?(Hash) ? klass.new(v) : v }
      end

      def has_many(name, klass, key = name.to_s)
        field(name, key) { |v| v.is_a?(Array) ? v.map { |item| item.is_a?(Hash) ? klass.new(item) : item } : v }
      end
    end

    # Raw access to any field, known or not.
    def [](key)
      raw[key.to_s]
    end

    def key?(key)
      raw.key?(key.to_s)
    end

    # Fields the API sent that this gem has no accessor for.
    def extra
      raw.reject { |k, _| self.class.known_keys.include?(k) }
    end

    def to_h
      raw
    end

    def to_json(*args)
      raw.to_json(*args)
    end

    def ==(other)
      other.class == self.class && other.raw == raw
    end
    alias eql? ==

    def hash
      [self.class, raw].hash
    end

    def inspect
      "#<#{self.class.name} #{raw.inspect}>"
    end
  end

  # One page of a cursor-paginated list: `{data: [...], next_cursor}`.
  class Page
    include Enumerable

    attr_reader :data, :next_cursor, :response, :raw

    def initialize(body, item_class, response: nil)
      @raw = body
      @data = Array(body["data"]).map { |item| item.is_a?(Hash) ? item_class.new(item) : item }
      @next_cursor = body["next_cursor"]
      @response = response
    end

    def each(&block)
      data.each(&block)
    end

    def to_h
      raw
    end
  end
end
