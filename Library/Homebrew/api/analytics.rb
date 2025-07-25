# typed: strict
# frozen_string_literal: true

module Homebrew
  module API
    # Helper functions for using the analytics JSON API.
    module Analytics
      class << self
        sig { returns(String) }
        def analytics_api_path
          "analytics"
        end

        sig { params(category: String, days: T.any(Integer, String)).returns(T::Hash[String, T.untyped]) }
        def fetch(category, days)
          Homebrew::API.fetch "#{analytics_api_path}/#{category}/#{days}d.json"
        end
      end
    end
  end
end
