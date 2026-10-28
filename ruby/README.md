# overpay (Ruby SDK)

A buyer client for the [Overpay](https://overpay.com) marketplace API: browse
listings, place and pay orders with merchant credits, hold a credit balance,
and stream a seller's output as it arrives.

The API is described by an OpenAPI document. This gem carries a copy
(`spec/`) together with the contract fixtures the marketplace's own tests
pin, and its test suite checks the SDK against both - so the gem and
the API can't silently drift apart.

The only runtime dependency is `bigdecimal`; everything else is Ruby's
standard library. NIP-98 signing (`require "overpay/nip98"`) additionally
needs the `ffi` gem and libsecp256k1.

## Install

```ruby
# Gemfile
gem "overpay", github: "fathom-x/overpay-sdk", glob: "ruby/*.gemspec"
```

## Quickstart

```ruby
require "overpay"

client = Overpay::Client.new(base_url: "https://overpay.com", token: ENV["OVERPAY_TOKEN"])

# Browse (no auth needed)
client.listings.list.each { |l| puts "#{l.title} - #{l.price_usd} (#{l.seller.slug})" }
listing = client.listings.get("listing-id")   # full description, schemas, variants

# Place and pay in one call (credits), then wait for the result
paid = client.place_and_pay(listing_id: listing.id, buyer_note: { prompt: "hello" })
final = client.wait(paid.order_id)            # polls until delivered / failed / cancelled / rejected
puts final.order.delivered_content
```

An API token comes from the marketplace's account page (API keys), from
`client.buyer.register` with a Nostr key, or from the OAuth login
(`Overpay::Flows::PkceFlow`).

## Streaming

A seller that produces its output incrementally publishes it as it goes. The
waiter polls the order, hands you each new piece, and refuses to re-download
an unchanged buffer (`since_seq`):

```ruby
client.stream(paid.order_id) { |delta| print delta }
# or, with every poll's state:
client.wait(paid.order_id, poll: 0.5, timeout: 120) do |event|
  print event.delta if event.delta
  puts "\n[#{event.order.fulfillment_status}]" unless event.pending?
end
```

`stream` also hands out whatever the preview missed once the order is
delivered (the preview buffer is capped at 32 KB and cleared on delivery). An
offloaded deliverable (`delivered_content_url`) is fetched and inlined for you;
binary files stay a link.

## Metered listings and spend sessions

```ruby
# Authorize the most the seller may charge; the rest is released on capture.
paid = client.place_and_pay(listing_id: id, buyer_note: { model: "cheap", prompt: "..." }, authorization_cents: 50)

# Or cap a whole session and let the marketplace size each turn:
session = client.spend_session(listing_id: id, cap_cents: 500, expires_in_seconds: 3600)
session.turn(buyer_note: { model: "cheap", messages: [...] }) { |delta| print delta }
session.remaining_cents
session.close
```

## Wallet (credits)

```ruby
wallet = client.wallet
wallet.core_balance_cents                       # BigDecimal cents
wallet.balances                                 # every credit held, by seller / organization
wallet.ledger(since: Time.now - 86_400).each { |t| puts "#{t.label} #{t.amount_cents}" }

load = wallet.load_core(amount_cents: 1000)     # a Lightning invoice
puts load.bolt11                                # pay it from any Lightning wallet...
wallet.wait_for_load(load.order_id)             # ...and wait for the marketplace to see it

purchase = wallet.buy_seller_credits("seller-slug", amount_cents: 500)
purchase.payment_address                        # USDC on Base, or pay in the browser at purchase.order_url
```

Crypto never passes through this gem: a load returns an invoice or an address
for your own wallet to pay.

## Quotes and shipping

Some listings are priced by the seller after you ask (`listing.request_quote?`)
or need a shipping address before payment (`listing.requires_shipping_address?`):

```ruby
order = client.request_quote(listing_id: id, buyer_note: "A left-handed widget, blue", quantity: 2)
order = client.wait_for_quote(order.id, timeout: 600)   # raises Overpay::QuoteDeclined if the seller declines
puts "#{order.quote.description}: #{order.total_usd}"
client.checkout(order.id, shipping_address: { name: "...", line1: "...", city: "...", postal_code: "...", country: "US" })
client.pay_with_credits("seller-slug", order.id)
```

Paying before checkout is complete fails with `Overpay::CheckoutIncomplete`.

## Errors

Every API error is an `Overpay::ApiError` with `status`, `code` (the API's
machine-readable code - match on it, never on the message), `api_message`,
`details` (the error body's other fields) and `body`. Common codes have
subclasses: `InsufficientCredits`, `NotFound`, `Unauthorized`,
`UnknownVariant`, `AuthorizationOutOfBounds`, `SpendAuthorizationError`,
`IdempotencyError`, `CheckoutInvalid`, `CheckoutIncomplete`, `QuoteError`.
Unknown codes arrive as a plain `ApiError`. A failed connection is an
`Overpay::TransportError`.

Retries are automatic where they are safe: GETs on 429/502/503/504 and
connection errors, and order creation under an automatic `Idempotency-Key`
(the API replays the first response to a repeat). Pass
`retry_ambiguous_writes: true` to also repeat a keyed write after a timeout.

## Money

Every `*_cents` field is a `BigDecimal` (sub-cent prices are real:
`0.0006` cents is a micropayment, not a rounding error). `Overpay::Money`
has `parse`, `ceil_cents`, `whole_cents`, `json_cents` and `format_usd`.

## Authentication

- `token:` - `Authorization: Bearer <token>` (the usual case).
- `signer:` - a NIP-98 signer (`Overpay::Nip98::Signer.new(private_key_hex)`,
  `require "overpay/nip98"`): with a token too, every request also carries an
  `X-Nostr-Signature` by the buyer's key; alone, `Authorization: Nostr ...`,
  which registration (`client.buyer.register`) requires.
- `auth:` on any call overrides the client's default for that one request.

## Testing your own code

```ruby
require "overpay/testing"
fake = Overpay::Testing::FakeOverpay.new            # answers every buyer operation from the contract fixtures
server = Overpay::Testing::Server.start(fake)       # a real socket, no dependencies
client = Overpay::Client.new(base_url: server.url, token: "t")
fake.stub(:get, "/api/v1/orders/abc", body: { data: { ... } })
fake.requests.last.json                             # what your code sent
server.stop
```

`FakeOverpay` is also a Rack app (`call(env)`).

## Development

```bash
cd ruby
bundle install
bundle exec rake test
bin/codegen --check     # lib/overpay/generated.rb matches spec/overpay-v1.json
```

The NIP-98 tests sign with the real libsecp256k1 when it is installed and
skip otherwise; CI sets `OVERPAY_REQUIRE_SECP256K1=1`, which turns a missing
library into a failure.

`spec/` is a copy of the API contract and is not edited by hand. When an
update to it changes an enum or an operation, run `bin/codegen`.
