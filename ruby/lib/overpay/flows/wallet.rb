# frozen_string_literal: true

module Overpay
  module Flows
    # The buyer's credit balances as a wallet: what is held, what moved,
    # and how to top up. Crypto never passes through this gem - a load
    # returns an invoice or an address for the app to pay from its own
    # wallet, and `wait_for_load` watches the marketplace notice it.
    class Wallet
      # The marketplace checks pending payments about once a minute.
      LOAD_POLL = 5.0
      LOAD_TIMEOUT = 15 * 60.0

      def initialize(client, auth: nil)
        @client = client
        @auth = auth
      end

      # Every credit held, by holder (seller- and organization-level).
      def balances
        @client.credits.list(auth: @auth)
      end

      # The core marketplace credit (the organization-held balance with
      # `core: true`), or nil when none is held.
      def core
        balances.find(&:core?)
      end

      # Core credits in cents (0 when none are held).
      def core_balance_cents
        core&.balance_cents || Money.parse(0)
      end

      # What can be spent at one seller (its organization's balance when it
      # is in one).
      def balance_at(seller_slug)
        @client.credits.balance(seller_slug, auth: @auth)
      end

      # The ledger, newest first, as a lazy Enumerator of CreditTransaction.
      def ledger(since: nil, credit_id: nil)
        @client.credits.transactions_all(since: since, credit_id: credit_id, auth: @auth)
      end

      # A Lightning invoice (`bolt11`) for `amount_cents` of core credits.
      # Pay it from any Lightning wallet, then `wait_for_load(load.order_id)`.
      def load_core(amount_cents:)
        @client.credits.load(amount_cents: amount_cents, auth: @auth)
      end

      # A credit-purchase order at a seller: pay `payment_amount_usdc` to
      # `payment_address` (USDC on Base), or any currency in the browser at
      # `order_url`; then `wait_for_load(purchase.order_id)`.
      def buy_seller_credits(seller_slug, amount_cents:)
        @client.credits.purchase(seller_slug, amount_cents: amount_cents, auth: @auth)
      end

      # Poll a load / purchase order until the marketplace sees it paid.
      # Returns the order (`paid?`), or the last snapshot on timeout - check
      # `paid?`.
      def wait_for_load(order_id, poll: LOAD_POLL, timeout: LOAD_TIMEOUT)
        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loop do
          order = @client.orders.get(order_id, auth: @auth)
          return order if order.paid? || %w[expired cancelled].include?(order.payment_status)

          elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
          return order if elapsed >= timeout

          @client.sleeper.call([poll, timeout - elapsed].min)
        end
      end
    end
  end
end
