# frozen_string_literal: true

require "bigdecimal"
require "bigdecimal/util"

module Overpay
  # The marketplace's money precision: every `*_cents` field is a decimal
  # with 4 places ($0.000001, one USDC base unit). Amounts arrive as JSON
  # numbers - Integers when whole, fractions otherwise (`9990.8444`) - and
  # must never be read as Integers: a balance with a sub-cent charge on it
  # would break. Every model parses its money through `Money.parse`.
  module Money
    CENTS_SCALE = 4

    module_function

    # A cents amount as BigDecimal, rounded half-up to the marketplace's
    # precision. Accepts Integer, Float, Rational, BigDecimal or a numeric
    # String; nil stays nil. Raises ArgumentError for anything else.
    def parse(value)
      return nil if value.nil?
      return value.round(CENTS_SCALE) if value.is_a?(BigDecimal)

      decimal =
        case value
        when Integer then BigDecimal(value)
        when Float then BigDecimal(value.to_s)
        when Rational then BigDecimal(value, CENTS_SCALE + 2)
        when String
          raise ArgumentError, "not a number: #{value.inspect}" unless value.match?(/\A\s*-?\d+(\.\d+)?\s*\z/)

          BigDecimal(value.strip)
        else
          raise ArgumentError, "not a money amount: #{value.inspect}"
        end
      decimal.round(CENTS_SCALE)
    end

    # A charge rounded *up* to the marketplace's precision.
    def ceil_cents(value)
      BigDecimal(value.to_s).round(CENTS_SCALE, BigDecimal::ROUND_CEILING)
    end

    # A buyer authorization is whole cents: the amount rounded up to a cent.
    def whole_cents(value)
      BigDecimal(value.to_s).ceil.to_i
    end

    # A cents amount as a JSON number: Integer when whole (the legacy
    # contract), Float otherwise - never the BigDecimal-as-String default.
    def json_cents(value)
      return nil if value.nil?

      bd = BigDecimal(value.to_s)
      bd.frac.zero? ? bd.to_i : bd.to_f
    end

    # A cents amount as dollars for display: `$12.34`, or `$0.000756` for a
    # sub-cent amount. Mirrors the marketplace's `Listing.format_cents_as_usd`.
    def format_usd(cents)
      return "$0.00" if cents.nil?

      dollars = (BigDecimal(cents.to_s) / 100).round(CENTS_SCALE + 2)
      int_part, frac_part = dollars.to_s("F").split(".")
      frac_part = (frac_part || "").ljust(2, "0").sub(/(\d{2,}?)0+\z/, '\1')
      "$#{int_part}.#{frac_part}"
    end
  end
end
