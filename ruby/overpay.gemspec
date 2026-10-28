# frozen_string_literal: true

require_relative "lib/overpay/version"

Gem::Specification.new do |spec|
  spec.name = "overpay"
  spec.version = Overpay::VERSION
  spec.authors = ["Overpay"]
  spec.summary = "Buyer SDK for the Overpay marketplace API"
  spec.description = "Browse listings, place and pay orders with merchant credits, hold a credit balance, " \
                     "and stream a seller's output as it arrives - a Ruby client for the Overpay buyer API."
  spec.homepage = "https://github.com/fathom-x/overpay-sdk"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "spec/**/*.json", "README.md"]
  spec.require_paths = ["lib"]

  # The only runtime dependency is bigdecimal (a bundled, not default, gem
  # since Ruby 3.4); net/http, json, openssl, securerandom and digest are
  # default gems. NIP-98 signing (`require "overpay/nip98"`) additionally
  # needs the ffi gem and libsecp256k1.
  spec.add_dependency "bigdecimal", ">= 3.1"

  spec.add_development_dependency "base64", ">= 0.2"
  # For the NIP-98 tests against the real libsecp256k1 (CI installs it).
  spec.add_development_dependency "ffi", "~> 1.16"
  spec.add_development_dependency "minitest", "~> 5.25"
  spec.add_development_dependency "rake", "~> 13.0"
end
