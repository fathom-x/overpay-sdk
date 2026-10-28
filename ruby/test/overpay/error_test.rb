# frozen_string_literal: true

require "test_helper"

class ErrorTest < Minitest::Test
  E = Overpay::ApiError

  def test_json_error_bodies_are_shown_as_they_are
    error = E.from_response(422, '{"error":"No available credits for this seller"}')
    assert_equal 'HTTP 422: {"error":"No available credits for this seller"}', error.message
    assert_equal "No available credits for this seller", error.api_message
    assert_nil error.code
    assert error.insufficient_credits?, "falls back to the body mentioning credits"
    assert_equal "HTTP 500: ", E.from_response(500, "").message
  end

  def test_codes_pick_the_subclass_and_keep_the_details
    error = E.from_response(402, fixture_text("error_insufficient_credits"))
    assert_instance_of Overpay::InsufficientCredits, error
    assert_equal "insufficient_credits", error.code
    assert error.known_code?
    assert_equal BigDecimal("50"), error.detail_cents(:authorization_cents)
    assert_equal({ "authorization_cents" => 50 }, error.details)

    variant = E.from_response(422, fixture_text("error_unknown_variant"))
    assert_instance_of Overpay::UnknownVariant, variant
    assert_equal %w[cheap premium], variant.detail(:variants)

    assert_instance_of Overpay::NotFound, E.from_response(404, fixture_text("error_not_found"))
    assert_instance_of Overpay::Unauthorized, E.from_response(401, fixture_text("error_unauthorized"))
    assert_instance_of Overpay::NotFound, E.from_response(404, "gone")
    assert_instance_of Overpay::IdempotencyError, E.from_response(409, '{"code":"idempotency_request_in_progress","error":"x"}')
  end

  def test_unknown_codes_are_tolerated
    error = E.from_response(422, '{"error":"new thing","code":"brand_new_code"}')
    assert_instance_of E, error
    assert_equal "brand_new_code", error.code
    refute error.known_code?
  end

  def test_a_firewall_block_page_becomes_one_sentence
    page = "<!DOCTYPE html>\n<html lang=\"en\">\n<head><title>Blocked</title>" \
           "<style>@font-face { src: url(\"data:font/woff2;base64,#{'A' * 200_000}\") }</style></head>\n" \
           "<body><h1 class=\"type-heading-04\">403 -\n Forbidden</h1></body></html>"
    error = E.from_response(403, page)
    assert_equal "HTTP 403: the server answered with a web page instead of a reply (\"403 - Forbidden\"). " \
                 "The request was blocked before it reached Overpay. Sending the same request again is likely " \
                 "to be blocked again.", error.message
    assert_equal page, error.body, "the body itself is kept whole"
  end

  def test_other_web_pages_name_their_heading_or_title
    assert_equal "HTTP 502: the server answered with a web page instead of a reply (\"Bad Gateway\").",
                 E.from_response(502, "<html><head><title>Bad Gateway</title></head><body>nginx</body></html>").message
    assert_equal "HTTP 503: the server answered with a web page instead of a reply.",
                 E.from_response(503, "<HTML><BODY>down</BODY></HTML>").message
  end

  def test_long_bodies_are_cut_on_a_character_boundary
    body = "é" * 1500 # 3000 bytes, 2 per character
    assert_equal "HTTP 500: #{'é' * 1000}... (1000 more bytes)", E.from_response(500, body).message
  end

  private

  def fixture_text(stem)
    File.read(File.join(Overpay::Testing::FIXTURE_DIR, "#{stem}.json"))
  end
end
