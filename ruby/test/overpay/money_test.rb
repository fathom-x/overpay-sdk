# frozen_string_literal: true

require "test_helper"

class MoneyTest < Minitest::Test
  M = Overpay::Money

  def test_parse_reads_every_json_number_shape_as_decimal_cents
    assert_equal BigDecimal("50"), M.parse(50)
    assert_equal BigDecimal("9990.8444"), M.parse(9990.8444)
    assert_equal BigDecimal("500"), M.parse("500.0")
    assert_equal BigDecimal("0.25"), M.parse(Rational(1, 4))
    assert_nil M.parse(nil)
    assert_equal BigDecimal("1.2346"), M.parse(1.23456)
  end

  def test_parse_rejects_non_numbers
    assert_raises(ArgumentError) { M.parse("five") }
    assert_raises(ArgumentError) { M.parse([]) }
  end

  def test_rounding_helpers
    assert_equal BigDecimal("0.0007"), M.ceil_cents(0.00061)
    assert_equal 51, M.whole_cents(50.01)
    assert_equal 50, M.whole_cents(BigDecimal("50"))
  end

  def test_json_cents_is_an_integer_when_whole
    assert_equal 50, M.json_cents(BigDecimal("50"))
    assert_in_delta 0.25, M.json_cents(BigDecimal("0.25"))
    assert_nil M.json_cents(nil)
  end

  def test_format_usd
    assert_equal "$12.34", M.format_usd(1234)
    assert_equal "$0.000756", M.format_usd(0.0756)
    assert_equal "$0.00", M.format_usd(nil)
    assert_equal "$5.00", M.format_usd(BigDecimal("500"))
  end
end
