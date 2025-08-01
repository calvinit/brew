# typed: strict
# frozen_string_literal: true

require "cachable"
require "api/download"

module Homebrew
  module API
    # Helper functions for using the formula JSON API.
    module Formula
      extend Cachable

      DEFAULT_API_FILENAME = "formula.jws.json"

      sig { returns(String) }
      def self.api_filename
        return DEFAULT_API_FILENAME unless ENV.fetch("HOMEBREW_USE_INTERNAL_API", false)

        "internal/formula.#{SimulateSystem.current_tag}.jws.json"
      end

      private_class_method :cache

      sig { params(name: String).returns(T::Hash[String, T.untyped]) }
      def self.fetch(name)
        Homebrew::API.fetch "formula/#{name}.json"
      end

      sig { params(formula: ::Formula).returns(::Formula) }
      def self.source_download(formula)
        path = formula.ruby_source_path || "Formula/#{formula.name}.rb"
        git_head = formula.tap_git_head || "HEAD"
        tap = formula.tap&.full_name || "Homebrew/homebrew-core"

        download = Homebrew::API::Download.new(
          "https://raw.githubusercontent.com/#{tap}/#{git_head}/#{path}",
          formula.ruby_source_checksum,
          cache: HOMEBREW_CACHE_API_SOURCE/"#{tap}/#{git_head}/Formula",
        )
        download.fetch

        with_env(HOMEBREW_FORBID_PACKAGES_FROM_PATHS: nil) do
          Formulary.factory(download.symlink_location,
                            formula.active_spec_sym,
                            alias_path: formula.alias_path,
                            flags:      formula.class.build_flags)
        end
      end

      sig { returns(Pathname) }
      def self.cached_json_file_path
        HOMEBREW_CACHE_API/api_filename
      end

      sig { returns(T::Boolean) }
      def self.download_and_cache_data!
        json_formulae, updated = Homebrew::API.fetch_json_api_file api_filename

        cache["aliases"] = {}
        cache["renames"] = {}
        cache["formulae"] = json_formulae.to_h do |json_formula|
          json_formula["aliases"].each do |alias_name|
            cache["aliases"][alias_name] = json_formula["name"]
          end
          (json_formula["oldnames"] || [json_formula["oldname"]].compact).each do |oldname|
            cache["renames"][oldname] = json_formula["name"]
          end

          [json_formula["name"], json_formula.except("name")]
        end

        updated
      end
      private_class_method :download_and_cache_data!

      sig { returns(T::Hash[String, T.untyped]) }
      def self.all_formulae
        unless cache.key?("formulae")
          json_updated = download_and_cache_data!
          write_names_and_aliases(regenerate: json_updated)
        end

        cache["formulae"]
      end

      sig { returns(T::Hash[String, String]) }
      def self.all_aliases
        unless cache.key?("aliases")
          json_updated = download_and_cache_data!
          write_names_and_aliases(regenerate: json_updated)
        end

        cache["aliases"]
      end

      sig { returns(T::Hash[String, String]) }
      def self.all_renames
        unless cache.key?("renames")
          json_updated = download_and_cache_data!
          write_names_and_aliases(regenerate: json_updated)
        end

        cache["renames"]
      end

      sig { returns(T::Hash[String, T.untyped]) }
      def self.tap_migrations
        # Not sure that we need to reload here.
        unless cache.key?("tap_migrations")
          json_updated = download_and_cache_data!
          write_names_and_aliases(regenerate: json_updated)
        end

        cache["tap_migrations"]
      end

      sig { returns(String) }
      def self.tap_git_head
        # Note sure we need to reload here.
        unless cache.key?("tap_git_head")
          json_updated = download_and_cache_data!
          write_names_and_aliases(regenerate: json_updated)
        end

        cache["tap_git_head"]
      end

      sig { params(regenerate: T::Boolean).void }
      def self.write_names_and_aliases(regenerate: false)
        download_and_cache_data! unless cache.key?("formulae")

        return unless Homebrew::API.write_names_file!(all_formulae.keys, "formula", regenerate:)

        (HOMEBREW_CACHE_API/"formula_aliases.txt").open("w") do |file|
          all_aliases.each do |alias_name, real_name|
            file.puts "#{alias_name}|#{real_name}"
          end
        end
      end
    end
  end
end
