# Overpay SDKs

Client SDKs for the [Overpay](https://overpay.com) marketplace API: browse
listings, place and pay orders with merchant credits, wait for (or stream) a
seller's output, and sign requests with NIP-98.

| Directory | Package | |
| --- | --- | --- |
| [`ruby/`](ruby/) | `overpay` gem | Ruby 3.2+ |
| [`rust/crates/overpay-sdk`](rust/crates/overpay-sdk) | `overpay-sdk` crate | Rust 1.88+ |
| [`rust/crates/overpay-nip98`](rust/crates/overpay-nip98) | `overpay-nip98` crate | NIP-98 request signing, no HTTP stack |

Both SDKs carry a copy of the API's OpenAPI document and contract fixtures in
their `spec/` directories, and their tests check the SDK against them.

## Ruby

```ruby
# Gemfile
gem "overpay", github: "fathom-x/overpay-sdk", glob: "ruby/*.gemspec"
```

See [`ruby/README.md`](ruby/README.md).

## Rust

```toml
[dependencies]
overpay-sdk = { git = "https://github.com/fathom-x/overpay-sdk" }
```

API docs: `cargo doc -p overpay-sdk --open` from `rust/`.

## Development

```bash
cd rust && cargo test --workspace
cd ruby && bundle install && bundle exec rake test
```

NIP-98 signing in Ruby needs libsecp256k1 (`apt install libsecp256k1-dev`,
`brew install secp256k1`).

## License

MIT
