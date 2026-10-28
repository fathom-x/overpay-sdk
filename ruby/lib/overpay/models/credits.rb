# frozen_string_literal: true

module Overpay
  module Models
    # A credit balance, held by a seller (`holder_type: seller`) or by an
    # organization (`organization`). Core marketplace credits are the
    # organization-held balance with `core: true`.
    class MerchantCredit < Model
      fields :id, :holder_type, :seller_slug, :seller_name, :organization_slug, :organization_name,
             :formatted_balance
      cents :balance_cents, :total_purchased_cents, :total_redeemed_cents
      booleans :core
      times :updated_at

      def seller_held?
        holder_type == "seller"
      end

      def organization_held?
        holder_type == "organization"
      end

      # The slug credits are spent at: the seller's, or the organization's.
      def slug
        seller_slug || organization_slug
      end
    end

    # The balance spendable at one seller (its organization's when it is in one).
    class MerchantCreditBalance < Model
      fields :seller_slug, :formatted_balance, :organization
      cents :balance_cents
    end

    # One movement on a credit: a load, a spend or a refund.
    class CreditTransaction < Model
      fields :id, :type, :label, :source, :credit_id, :holder_type, :seller_slug, :organization_slug,
             :order_id, :order_title, :redemption_id
      cents :amount_cents, :balance_before_cents, :balance_after_cents
      booleans :core
      times :created_at

      def load?
        type == CreditTransactionType::LOAD
      end

      def spend?
        type == CreditTransactionType::SPEND
      end

      def refund?
        type == CreditTransactionType::REFUND
      end
    end

    # A Lightning invoice for loading core credits.
    class CreditLoad < Model
      fields :order_id, :bolt11, :payment_hash, :sats, :order_url
      cents :amount_cents
      times :expires_at
    end

    # A pending credit-purchase order at a seller, with its USDC payment
    # address when the seller takes USDC.
    class CreditPurchase < Model
      fields :order_id, :order_type, :payment_status, :order_url, :message, :beneficiary_organization,
             :payment_address, :payment_amount_usdc
      cents :total_usd_cents
      times :payment_expires_at
    end

    # How redeeming merchant credits against an order went.
    class Redemption < Model
      fields :status, :message
      cents :amount_redeemed_cents, :credit_balance_cents

      def settled?
        [RedemptionStatus::FULLY_PAID, RedemptionStatus::ALREADY_PAID].include?(status)
      end
    end
  end
end
