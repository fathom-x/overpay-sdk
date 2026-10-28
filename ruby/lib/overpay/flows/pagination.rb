# frozen_string_literal: true

require "set"

module Overpay
  module Flows
    # Walking cursor-paginated lists.
    module Pagination
      module_function

      # Every page of a list, lazily: the block fetches a page for a cursor
      # (nil for the first). A cursor the server already handed out ends the
      # walk - following it again could only repeat pages, forever.
      def each_page
        Enumerator.new do |y|
          cursor = nil
          seen = Set.new
          loop do
            page = yield(cursor)
            y << page
            cursor = page.next_cursor
            break if cursor.nil? || cursor.to_s.empty? || !seen.add?(cursor)
          end
        end.lazy
      end

      # Every item of a list, page by page.
      def each_item(&fetch)
        each_page(&fetch).flat_map(&:data)
      end
    end
  end
end
