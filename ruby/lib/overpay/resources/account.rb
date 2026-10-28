# frozen_string_literal: true

module Overpay
  module Resources
    class Account < Base
      # The authenticated buyer.
      def get(auth: nil)
        model(Models::Account, execute(Request.get("/api/v1/account"), auth_for(auth)))
      end
    end
  end
end
