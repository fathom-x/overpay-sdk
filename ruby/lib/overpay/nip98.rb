# frozen_string_literal: true

# NIP-98 HTTP auth (kind 27235) signing. Optional: `require "overpay/nip98"`.
#
# The default backend binds libsecp256k1 over the ffi gem (`gem install
# ffi`; `apt-get install libsecp256k1-dev` / `brew install secp256k1`). Any
# object responding to `pubkey(secret_key_bytes)` → 32 x-only bytes and
# `schnorr_sign(message_bytes, secret_key_bytes)` → 64 signature bytes can
# stand in for it (`Signer.new(key, backend: ...)`).

require "json"
require "digest"
require "securerandom"
require_relative "error"

module Overpay
  module Nip98
    KIND = 27235

    class InvalidKey < SignError; end

    # Signs NIP-98 events for one secp256k1 secret key (32 bytes hex, with
    # or without `0x`). `Debug`-safe: never prints the key.
    class Signer
      attr_reader :backend

      def initialize(private_key_hex, backend: nil)
        hex = private_key_hex.to_s.strip.delete_prefix("0x")
        raise InvalidKey, "secret key must be 32 bytes of hex" unless hex.match?(/\A[0-9a-fA-F]{64}\z/)

        @secret = [hex].pack("H*")
        @backend = backend
      end

      def backend
        @backend ||= Secp256k1Ffi
      end

      # The x-only public key, hex.
      def pubkey
        @pubkey ||= backend.pubkey(@secret).unpack1("H*")
      end

      # An `Authorization` header value for `method url`; `body` is the
      # exact request bytes (its sha256 rides as the `payload` tag), or nil.
      def sign_nip98(url:, method:, body: nil, created_at: Time.now.to_i)
        "Nostr #{[JSON.generate(event(url: url, method: method, body: body, created_at: created_at))].pack('m0')}"
      end

      # The signed event as a Hash.
      def event(url:, method:, body: nil, created_at: Time.now.to_i)
        tags = [["u", url.to_s], ["method", method.to_s.upcase]]
        tags << ["payload", Digest::SHA256.hexdigest(body)] if body
        serialized = JSON.generate([0, pubkey, created_at, KIND, tags, ""])
        id = Digest::SHA256.hexdigest(serialized)
        sig = backend.schnorr_sign([id].pack("H*"), @secret).unpack1("H*")
        { "id" => id, "pubkey" => pubkey, "created_at" => created_at, "kind" => KIND,
          "tags" => tags, "content" => "", "sig" => sig }
      end

      def inspect
        "#<Overpay::Nip98::Signer pubkey=#{@pubkey ? pubkey[0, 8] : '?'}...>"
      end
    end

    # libsecp256k1 over FFI, loaded on first use.
    module Secp256k1Ffi
      LIB_NAMES = %w[libsecp256k1.dylib libsecp256k1.so libsecp256k1.so.2 libsecp256k1.so.1 libsecp256k1.so.0 secp256k1].freeze
      CONTEXT_NONE = 1

      module_function

      def lib
        @lib ||= begin
          require "ffi"
          mod = Module.new do
            extend FFI::Library
            ffi_lib LIB_NAMES
            attach_function :secp256k1_context_create, [:uint32], :pointer
            attach_function :secp256k1_context_randomize, [:pointer, :pointer], :int
            attach_function :secp256k1_keypair_create, [:pointer, :pointer, :pointer], :int
            attach_function :secp256k1_keypair_xonly_pub, [:pointer, :pointer, :pointer, :pointer], :int
            attach_function :secp256k1_xonly_pubkey_serialize, [:pointer, :pointer, :pointer], :int
            attach_function :secp256k1_schnorrsig_sign32, [:pointer, :pointer, :pointer, :pointer, :pointer], :int
          end
          ctx = mod.secp256k1_context_create(CONTEXT_NONE)
          seed = FFI::MemoryPointer.new(:uint8, 32).put_bytes(0, SecureRandom.random_bytes(32))
          mod.secp256k1_context_randomize(ctx, seed)
          [mod, ctx]
        rescue LoadError => e
          raise LoadError, "Could not load libsecp256k1 for NIP-98 signing. Install the ffi gem and " \
                           "libsecp256k1 (apt-get install libsecp256k1-dev / brew install secp256k1). #{e.message}"
        end
      end

      def keypair(secret)
        mod, ctx = lib
        sk = FFI::MemoryPointer.new(:uint8, 32).put_bytes(0, secret)
        pair = FFI::MemoryPointer.new(:uint8, 96)
        raise InvalidKey, "not a valid secp256k1 secret key" unless mod.secp256k1_keypair_create(ctx, pair, sk) == 1

        pair
      end

      def pubkey(secret)
        mod, ctx = lib
        pair = keypair(secret)
        xonly = FFI::MemoryPointer.new(:uint8, 64)
        raise SignError, "keypair_xonly_pub failed" unless mod.secp256k1_keypair_xonly_pub(ctx, xonly, nil, pair) == 1

        out = FFI::MemoryPointer.new(:uint8, 32)
        raise SignError, "xonly_pubkey_serialize failed" unless mod.secp256k1_xonly_pubkey_serialize(ctx, out, xonly) == 1

        out.get_bytes(0, 32)
      end

      def schnorr_sign(message, secret)
        mod, ctx = lib
        pair = keypair(secret)
        msg = FFI::MemoryPointer.new(:uint8, 32).put_bytes(0, message)
        sig = FFI::MemoryPointer.new(:uint8, 64)
        raise SignError, "schnorrsig_sign32 failed" unless mod.secp256k1_schnorrsig_sign32(ctx, sig, msg, pair, nil) == 1

        sig.get_bytes(0, 64)
      end
    end
  end
end
