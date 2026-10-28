# frozen_string_literal: true

require "test_helper"

class Nip98Test < Minitest::Test
  def test_event_shape_with_a_fake_backend
    signer = Overpay::Nip98::Signer.new("0x" + "ab" * 32, backend: Overpay::TestSupport::FakeSchnorr.new)
    event = signer.event(url: "https://overpay.example/api/v1/buyer/register", method: "post", body: '{"a":1}', created_at: 1_700_000_000)
    assert_equal 27235, event["kind"]
    assert_equal [["u", "https://overpay.example/api/v1/buyer/register"], ["method", "POST"],
                  ["payload", Digest::SHA256.hexdigest('{"a":1}')]], event["tags"]
    expected_id = Digest::SHA256.hexdigest(JSON.generate([0, signer.pubkey, 1_700_000_000, 27235, event["tags"], ""]))
    assert_equal expected_id, event["id"]
    assert_equal 128, event["sig"].length
    header = signer.sign_nip98(url: "https://x/y", method: "GET")
    assert_match(/\ANostr [A-Za-z0-9+\/=]+\z/, header)
    assert_nil JSON.parse(Base64.strict_decode64(header.delete_prefix("Nostr ")))["tags"].to_h["payload"]
    refute_includes signer.inspect, "ab" * 32
  end

  def test_the_signer_loads_on_its_own
    lib = File.expand_path("../../lib", __dir__)
    script = 'require "overpay/nip98"; puts Overpay::Nip98::Signer.new("ab" * 32).class; ' \
             'puts Overpay::Nip98::InvalidKey.ancestors.include?(Overpay::Error)'
    out = IO.popen([RbConfig.ruby, "-I", lib, "-e", script], err: %i[child out], &:read)
    assert_equal "Overpay::Nip98::Signer\ntrue\n", out
  end

  def test_rejects_malformed_keys
    assert_raises(Overpay::Nip98::InvalidKey) { Overpay::Nip98::Signer.new("abc") }
  end

  # x-coordinate of the secp256k1 generator G: the public key of secret key 1.
  GENERATOR_X = "79be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798"

  # Signs with the real libsecp256k1 and checks the result with the
  # library's own BIP-340 verifier. Skipped where the library or the ffi
  # gem is missing - except under OVERPAY_REQUIRE_SECP256K1=1 (CI), where a
  # missing library is a failure, so the real path can't silently stop
  # being tested.
  def test_real_libsecp256k1_signs_verifiable_events
    signer = Overpay::Nip98::Signer.new("00" * 31 + "01")
    begin
      pubkey = signer.pubkey
    rescue LoadError => e
      flunk "libsecp256k1 / ffi not available: #{e.message}" if ENV["OVERPAY_REQUIRE_SECP256K1"] == "1"
      skip "libsecp256k1 / ffi not available: #{e.message}"
    end
    assert_equal GENERATOR_X, pubkey

    body = '{"listing_id":"L1"}'
    event = signer.event(url: "https://overpay.example/api/v1/orders", method: "post", body: body)
    assert_equal Digest::SHA256.hexdigest(body), event["tags"].to_h["payload"]
    assert schnorr_valid?(event["sig"], event["id"], pubkey), "libsecp256k1 rejects its own signature"

    tampered = event["id"].sub(/\A./) { |c| c == "0" ? "1" : "0" }
    refute schnorr_valid?(event["sig"], tampered, pubkey), "a signature must not verify over another event id"

    header = signer.sign_nip98(url: "https://overpay.example/api/v1/account", method: "GET")
    decoded = JSON.parse(header.delete_prefix("Nostr ").unpack1("m0"))
    assert schnorr_valid?(decoded["sig"], decoded["id"], pubkey)
  end

  def test_an_out_of_range_secret_key_is_refused_by_the_library
    # The group order n itself: 32 bytes of hex, but not a valid secret key.
    signer = Overpay::Nip98::Signer.new("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141")
    begin
      Overpay::Nip98::Secp256k1Ffi.lib
    rescue LoadError => e
      flunk "libsecp256k1 / ffi not available: #{e.message}" if ENV["OVERPAY_REQUIRE_SECP256K1"] == "1"
      skip "libsecp256k1 / ffi not available: #{e.message}"
    end
    assert_raises(Overpay::Nip98::InvalidKey) { signer.pubkey }
  end

  private

  # BIP-340 verification through libsecp256k1, bound here for the test only.
  def schnorr_valid?(sig_hex, msg_hex, pubkey_hex)
    lib = Nip98Verify.lib
    ctx = lib.secp256k1_context_create(1)
    xonly = FFI::MemoryPointer.new(:uint8, 64)
    raw = FFI::MemoryPointer.new(:uint8, 32).put_bytes(0, [pubkey_hex].pack("H*"))
    return false unless lib.secp256k1_xonly_pubkey_parse(ctx, xonly, raw) == 1

    sig = FFI::MemoryPointer.new(:uint8, 64).put_bytes(0, [sig_hex].pack("H*"))
    msg = FFI::MemoryPointer.new(:uint8, 32).put_bytes(0, [msg_hex].pack("H*"))
    lib.secp256k1_schnorrsig_verify(ctx, sig, msg, 32, xonly) == 1
  end

  module Nip98Verify
    def self.lib
      @lib ||= Module.new do
        extend FFI::Library
        ffi_lib Overpay::Nip98::Secp256k1Ffi::LIB_NAMES
        attach_function :secp256k1_context_create, [:uint32], :pointer
        attach_function :secp256k1_xonly_pubkey_parse, [:pointer, :pointer, :pointer], :int
        attach_function :secp256k1_schnorrsig_verify, [:pointer, :pointer, :pointer, :size_t, :pointer], :int
      end
    end
  end
end
