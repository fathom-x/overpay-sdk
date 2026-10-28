# frozen_string_literal: true

module Overpay
  module Models
    class Account < Model
      fields :account_number, :formatted_account_number, :username
    end

    # The result of NIP-98 registration: the account and a fresh API token.
    class BuyerRegistration < Model
      fields :user_id, :account_number, :nostr_pubkey, :token, :token_name

      def inspect
        "#<Overpay::Models::BuyerRegistration account_number=#{account_number} token=[redacted]>"
      end
    end

    # A one-time browser login link.
    class WebSession < Model
      fields :login_url, :expires_at
    end
  end
end
