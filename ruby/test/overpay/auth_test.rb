# frozen_string_literal: true

require "test_helper"

class AuthTest < Minitest::Test
  FakeSigner = Struct.new(:raise_with) do
    def sign_nip98(url:, method:, body: nil)
      raise raise_with if raise_with

      "Nostr signed:#{method}:#{url}:#{body.nil? ? '-' : body.bytesize}"
    end
  end

  def test_coerce_accepts_every_credential_shape
    assert_same Overpay::Auth::NONE, Overpay::Auth.coerce(nil)
    assert Overpay::Auth::NONE.none?
    bearer = Overpay::Auth.coerce("tok")
    assert_equal :bearer, bearer.kind
    assert_same bearer, Overpay::Auth.coerce(bearer)
    assert_equal :nip98, Overpay::Auth.coerce(FakeSigner.new).kind
    assert_raises(ArgumentError) { Overpay::Auth.coerce(42) }
    assert_equal "#<Overpay::Auth bearer>", bearer.inspect
    assert_equal bearer.inspect, bearer.to_s
  end

  def test_headers_per_kind
    signer = FakeSigner.new
    assert_equal({}, Overpay::Auth::NONE.headers("GET", "http://x/y", nil))
    assert_equal({ "Authorization" => "Bearer tok" }, Overpay::Auth.bearer("tok").headers("GET", "http://x/y", nil))
    assert_equal({ "Authorization" => "Nostr signed:POST:http://x/y:2" },
                 Overpay::Auth.nip98(signer).headers("POST", "http://x/y", "{}"))
    assert_equal({ "Authorization" => "Bearer tok", "X-Nostr-Signature" => "Nostr signed:GET:http://x/y:-" },
                 Overpay::Auth.bearer_signed("tok", signer).headers("GET", "http://x/y", nil))
  end

  def test_a_token_with_a_line_break_cannot_become_a_header
    assert_raises(Overpay::SignError) { Overpay::Auth.bearer("to\nk").headers("GET", "http://x/y", nil) }
  end

  def test_signer_failures_surface_as_sign_errors
    error = assert_raises(Overpay::SignError) do
      Overpay::Auth.nip98(FakeSigner.new(RuntimeError.new("no key"))).headers("GET", "http://x/y", nil)
    end
    assert_match(/nip98 sign: no key/, error.message)
    own = Overpay::Nip98::InvalidKey.new("bad")
    assert_same own, assert_raises(Overpay::SignError) { Overpay::Auth.nip98(FakeSigner.new(own)).headers("GET", "http://x", nil) }
  end
end
