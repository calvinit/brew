# typed: true # rubocop:todo Sorbet/StrictSigil
# frozen_string_literal: true

require "digest/sha2"
require "cachable"
require "tab"
require "utils"
require "utils/bottles"
require "service"
require "utils/curl"
require "deprecate_disable"
require "extend/hash/deep_transform_values"
require "extend/hash/keys"
require "tap"

# The {Formulary} is responsible for creating instances of {Formula}.
# It is not meant to be used directly from formulae.
module Formulary
  extend Context
  extend Cachable

  ALLOWED_URL_SCHEMES = %w[file].freeze
  private_constant :ALLOWED_URL_SCHEMES

  # `:codesign` and custom requirement classes are not supported.
  API_SUPPORTED_REQUIREMENTS = [:arch, :linux, :macos, :maximum_macos, :xcode].freeze
  private_constant :API_SUPPORTED_REQUIREMENTS

  # Enable the factory cache.
  #
  # @api internal
  sig { void }
  def self.enable_factory_cache!
    @factory_cache = true
  end

  def self.factory_cached?
    !@factory_cache.nil?
  end

  def self.platform_cache
    cache["#{Homebrew::SimulateSystem.current_os}_#{Homebrew::SimulateSystem.current_arch}"] ||= {}
  end

  def self.formula_class_defined_from_path?(path)
    platform_cache.key?(:path) && platform_cache[:path].key?(path)
  end

  def self.formula_class_defined_from_api?(name)
    platform_cache.key?(:api) && platform_cache[:api].key?(name)
  end

  def self.formula_class_get_from_path(path)
    platform_cache[:path].fetch(path)
  end

  def self.formula_class_get_from_api(name)
    platform_cache[:api].fetch(name)
  end

  def self.clear_cache
    platform_cache.each do |type, cached_objects|
      next if type == :formulary_factory

      cached_objects.each_value do |klass|
        class_name = klass.name

        # Already removed from namespace.
        next if class_name.nil?

        namespace = Utils.deconstantize(class_name)
        next if Utils.deconstantize(namespace) != name

        remove_const(Utils.demodulize(namespace).to_sym)
      end
    end

    super
  end

  module PathnameWriteMkpath
    # TODO: migrate away from refinements here, they don't play nicely with
    # Sorbet, when we migrate to `typed: strict`
    # rubocop:todo Sorbet/BlockMethodDefinition
    refine Pathname do
      def write(content, offset = nil, **open_args)
        T.bind(self, Pathname)
        raise "Will not overwrite #{self}" if exist? && !offset && !open_args[:mode]&.match?(/^a\+?$/)

        dirname.mkpath

        super
      end
    end
    # rubocop:enable Sorbet/BlockMethodDefinition
  end

  using PathnameWriteMkpath
  def self.load_formula(name, path, contents, namespace, flags:, ignore_errors:)
    raise "Formula loading disabled by HOMEBREW_DISABLE_LOAD_FORMULA!" if Homebrew::EnvConfig.disable_load_formula?

    require "formula"
    require "ignorable"
    require "stringio"

    # Capture stdout to prevent formulae from printing to stdout unexpectedly.
    old_stdout = $stdout
    $stdout = StringIO.new

    mod = Module.new
    remove_const(namespace) if const_defined?(namespace)
    const_set(namespace, mod)

    eval_formula = lambda do
      # Set `BUILD_FLAGS` in the formula's namespace so we can
      # access them from within the formula's class scope.
      mod.const_set(:BUILD_FLAGS, flags)
      mod.module_eval(contents, path)
    rescue NameError, ArgumentError, ScriptError, MethodDeprecatedError, MacOSVersion::Error => e
      if e.is_a?(Ignorable::ExceptionMixin)
        e.ignore
      else
        remove_const(namespace)
        raise FormulaUnreadableError.new(name, e)
      end
    end
    if ignore_errors
      Ignorable.hook_raise(&eval_formula)
    else
      eval_formula.call
    end

    class_name = class_s(name)

    begin
      mod.const_get(class_name)
    rescue NameError => e
      class_list = mod.constants
                      .map { |const_name| mod.const_get(const_name) }
                      .grep(Class)
      new_exception = FormulaClassUnavailableError.new(name, path, class_name, class_list)
      remove_const(namespace)
      raise new_exception, "", e.backtrace
    end
  ensure
    # TODO: Make printing to stdout an error so that we can print a tap name.
    # See discussion at https://github.com/Homebrew/brew/pull/20226#discussion_r2195886888
    if (printed_to_stdout = $stdout.string.strip.presence)
      opoo <<~WARNING
        Formula #{name} attempted to print the following while being loaded:
        #{printed_to_stdout}
      WARNING
    end
    $stdout = old_stdout
  end

  sig { params(identifier: String).returns(String) }
  def self.namespace_key(identifier)
    Digest::SHA2.hexdigest(
      "#{Homebrew::SimulateSystem.current_os}_#{Homebrew::SimulateSystem.current_arch}:#{identifier}",
    )
  end

  sig {
    params(name: String, path: Pathname, flags: T::Array[String], ignore_errors: T::Boolean)
      .returns(T.class_of(Formula))
  }
  def self.load_formula_from_path(name, path, flags:, ignore_errors:)
    contents = path.open("r") { |f| ensure_utf8_encoding(f).read }
    namespace = "FormulaNamespace#{namespace_key(path.to_s)}"
    klass = load_formula(name, path, contents, namespace, flags:, ignore_errors:)
    platform_cache[:path] ||= {}
    platform_cache[:path][path] = klass
  end

  sig { params(name: String, flags: T::Array[String]).returns(T.class_of(Formula)) }
  def self.load_formula_from_api!(name, flags:)
    namespace = :"FormulaNamespaceAPI#{namespace_key(name)}"

    mod = Module.new
    remove_const(namespace) if const_defined?(namespace)
    const_set(namespace, mod)

    mod.const_set(:BUILD_FLAGS, flags)

    class_name = class_s(name)
    json_formula = Homebrew::API::Formula.all_formulae[name]
    raise FormulaUnavailableError, name if json_formula.nil?

    json_formula = Homebrew::API.merge_variations(json_formula)

    uses_from_macos_names = json_formula.fetch("uses_from_macos", []).map do |dep|
      next dep unless dep.is_a? Hash

      dep.keys.first
    end

    requirements = {}
    json_formula["requirements"]&.map do |req|
      req_name = req["name"].to_sym
      next if API_SUPPORTED_REQUIREMENTS.exclude?(req_name)

      req_version = case req_name
      when :arch
        req["version"]&.to_sym
      when :macos, :maximum_macos
        MacOSVersion::SYMBOLS.key(req["version"])
      else
        req["version"]
      end

      req_tags = []
      req_tags << req_version if req_version.present?
      req_tags += req["contexts"]&.map do |tag|
        case tag
        when String
          tag.to_sym
        when Hash
          tag.deep_transform_keys(&:to_sym)
        else
          tag
        end
      end

      spec_hash = req_tags.empty? ? req_name : { req_name => req_tags }

      specs = req["specs"]
      specs ||= ["stable", "head"] # backwards compatibility
      specs.each do |spec|
        requirements[spec.to_sym] ||= []
        requirements[spec.to_sym] << spec_hash
      end
    end

    add_deps = lambda do |spec|
      T.bind(self, SoftwareSpec)

      dep_json = json_formula.fetch("#{spec}_dependencies", json_formula)

      dep_json["dependencies"]&.each do |dep|
        # Backwards compatibility check - uses_from_macos used to be a part of dependencies on Linux
        next if !json_formula.key?("uses_from_macos_bounds") && uses_from_macos_names.include?(dep) &&
                !Homebrew::SimulateSystem.simulating_or_running_on_macos?

        depends_on dep
      end

      [:build, :test, :recommended, :optional].each do |type|
        dep_json["#{type}_dependencies"]&.each do |dep|
          # Backwards compatibility check - uses_from_macos used to be a part of dependencies on Linux
          next if !json_formula.key?("uses_from_macos_bounds") && uses_from_macos_names.include?(dep) &&
                  !Homebrew::SimulateSystem.simulating_or_running_on_macos?

          depends_on dep => type
        end
      end

      dep_json["uses_from_macos"]&.each_with_index do |dep, index|
        bounds = dep_json.fetch("uses_from_macos_bounds", [])[index].dup || {}
        bounds.deep_transform_keys!(&:to_sym)
        bounds.deep_transform_values!(&:to_sym)

        if dep.is_a?(Hash)
          uses_from_macos dep.deep_transform_values(&:to_sym).merge(bounds)
        else
          uses_from_macos dep, bounds
        end
      end
    end

    # TODO: migrate away from this inline class here, they don't play nicely with
    # Sorbet, when we migrate to `typed: strict`
    # rubocop:todo Sorbet/BlockMethodDefinition
    klass = Class.new(::Formula) do
      @loaded_from_api = true

      desc json_formula["desc"]
      homepage json_formula["homepage"]
      license SPDX.string_to_license_expression(json_formula["license"])
      revision json_formula.fetch("revision", 0)
      version_scheme json_formula.fetch("version_scheme", 0)

      if (urls_stable = json_formula["urls"]["stable"].presence)
        stable do
          url_spec = {
            tag:      urls_stable["tag"],
            revision: urls_stable["revision"],
            using:    urls_stable["using"]&.to_sym,
          }.compact
          url urls_stable["url"], **url_spec
          version json_formula["versions"]["stable"]
          sha256 urls_stable["checksum"] if urls_stable["checksum"].present?

          instance_exec(:stable, &add_deps)
          requirements[:stable]&.each do |req|
            depends_on req
          end
        end
      end

      if (urls_head = json_formula["urls"]["head"].presence)
        head do
          url_spec = {
            branch: urls_head["branch"],
            using:  urls_head["using"]&.to_sym,
          }.compact
          url urls_head["url"], **url_spec

          instance_exec(:head, &add_deps)
          requirements[:head]&.each do |req|
            depends_on req
          end
        end
      end

      if (because = json_formula["no_autobump_msg"])
        no_autobump!(because:)
      end

      bottles_stable = json_formula["bottle"]["stable"].presence

      if bottles_stable
        bottle do
          if Homebrew::EnvConfig.bottle_domain == HOMEBREW_BOTTLE_DEFAULT_DOMAIN
            root_url HOMEBREW_BOTTLE_DEFAULT_DOMAIN
          else
            root_url Homebrew::EnvConfig.bottle_domain
          end
          rebuild bottles_stable["rebuild"]
          bottles_stable["files"].each do |tag, bottle_spec|
            cellar = Formulary.convert_to_string_or_symbol bottle_spec["cellar"]
            sha256 cellar:, tag.to_sym => bottle_spec["sha256"]
          end
        end
      end

      if (pour_bottle_only_if = json_formula["pour_bottle_only_if"])
        pour_bottle? only_if: pour_bottle_only_if.to_sym
      end

      if (keg_only_reason = json_formula["keg_only_reason"].presence)
        reason = Formulary.convert_to_string_or_symbol keg_only_reason["reason"]
        keg_only reason, keg_only_reason["explanation"]
      end

      if (deprecation_date = json_formula["deprecation_date"].presence)
        reason = DeprecateDisable.to_reason_string_or_symbol json_formula["deprecation_reason"], type: :formula
        deprecate! date: deprecation_date, because: reason
      end

      if (disable_date = json_formula["disable_date"].presence)
        reason = DeprecateDisable.to_reason_string_or_symbol json_formula["disable_reason"], type: :formula
        disable! date: disable_date, because: reason
      end

      json_formula["conflicts_with"]&.each_with_index do |conflict, index|
        conflicts_with conflict, because: json_formula.dig("conflicts_with_reasons", index)
      end

      json_formula["link_overwrite"]&.each do |overwrite_path|
        link_overwrite overwrite_path
      end

      def install
        raise "Cannot build from source from abstract formula."
      end

      @post_install_defined_boolean = json_formula["post_install_defined"]
      @post_install_defined_boolean = true if @post_install_defined_boolean.nil? # Backwards compatibility
      def post_install_defined?
        self.class.instance_variable_get(:@post_install_defined_boolean)
      end

      if (service_hash = json_formula["service"].presence)
        service_hash = Homebrew::Service.from_hash(service_hash)
        service do
          T.bind(self, Homebrew::Service)

          if (run_params = service_hash.delete(:run).presence)
            case run_params
            when Hash
              run(**run_params)
            when Array, String
              run run_params
            end
          end

          if (name_params = service_hash.delete(:name).presence)
            name(**name_params)
          end

          service_hash.each do |key, arg|
            public_send(key, arg)
          end
        end
      end

      @caveats_string = json_formula["caveats"]
      def caveats
        caveats_string = self.class.instance_variable_get(:@caveats_string)
        return unless caveats_string

        caveats_string.gsub(HOMEBREW_PREFIX_PLACEHOLDER, HOMEBREW_PREFIX)
                      .gsub(HOMEBREW_CELLAR_PLACEHOLDER, HOMEBREW_CELLAR)
                      .gsub(HOMEBREW_HOME_PLACEHOLDER, Dir.home)
      end

      @tap_git_head_string = json_formula["tap_git_head"]

      def tap_git_head
        self.class.instance_variable_get(:@tap_git_head_string)
      end

      @oldnames_array = json_formula["oldnames"] || [json_formula["oldname"]].compact
      def oldnames
        self.class.instance_variable_get(:@oldnames_array)
      end

      @aliases_array = json_formula.fetch("aliases", [])
      def aliases
        self.class.instance_variable_get(:@aliases_array)
      end

      @versioned_formulae_array = json_formula.fetch("versioned_formulae", [])
      def versioned_formulae_names
        self.class.instance_variable_get(:@versioned_formulae_array)
      end

      @ruby_source_path_string = json_formula["ruby_source_path"]
      def ruby_source_path
        self.class.instance_variable_get(:@ruby_source_path_string)
      end

      @ruby_source_checksum_string = json_formula.dig("ruby_source_checksum", "sha256")
      @ruby_source_checksum_string ||= json_formula["ruby_source_sha256"]
      def ruby_source_checksum
        checksum = self.class.instance_variable_get(:@ruby_source_checksum_string)
        Checksum.new(checksum) if checksum
      end
    end
    # rubocop:enable Sorbet/BlockMethodDefinition

    mod.const_set(class_name, klass)

    platform_cache[:api] ||= {}
    platform_cache[:api][name] = klass
  end

  sig {
    params(name: String, spec: T.nilable(Symbol), force_bottle: T::Boolean, flags: T::Array[String]).returns(Formula)
  }
  def self.resolve(
    name,
    spec: nil,
    force_bottle: false,
    flags: []
  )
    if name.include?("/") || File.exist?(name)
      f = factory(name, *spec, force_bottle:, flags:)
      if f.any_version_installed?
        tab = Tab.for_formula(f)
        resolved_spec = spec || tab.spec
        f.active_spec = resolved_spec if f.send(resolved_spec)
        f.build = tab
        if f.head? && tab.tabfile
          k = Keg.new(tab.tabfile.parent)
          f.version.update_commit(k.version.version.commit) if k.version.head?
        end
      end
    else
      rack = to_rack(name)
      alias_path = factory(name, force_bottle:, flags:).alias_path
      f = from_rack(rack, *spec, alias_path:, force_bottle:, flags:)
    end

    # If this formula was installed with an alias that has since changed,
    # then it was specified explicitly in ARGV. (Using the alias would
    # instead have found the new formula.)
    #
    # Because of this, the user is referring to this specific formula,
    # not any formula targeted by the same alias, so in this context
    # the formula shouldn't be considered outdated if the alias used to
    # install it has changed.
    f.follow_installed_alias = false

    f
  end

  def self.ensure_utf8_encoding(io)
    io.set_encoding(Encoding::UTF_8)
  end

  def self.class_s(name)
    class_name = name.capitalize
    class_name.gsub!(/[-_.\s]([a-zA-Z0-9])/) { T.must(Regexp.last_match(1)).upcase }
    class_name.tr!("+", "x")
    class_name.sub!(/(.)@(\d)/, "\\1AT\\2")
    class_name
  end

  def self.convert_to_string_or_symbol(string)
    return string[1..].to_sym if string.start_with?(":")

    string
  end

  # A {FormulaLoader} returns instances of formulae.
  # Subclasses implement loaders for particular sources of formulae.
  class FormulaLoader
    include Context

    # The formula's name.
    sig { returns(String) }
    attr_reader :name

    # The formula file's path.
    sig { returns(Pathname) }
    attr_reader :path

    # The name used to install the formula.
    sig { returns(T.nilable(Pathname)) }
    attr_reader :alias_path

    # The formula's tap (`nil` if it should be implicitly determined).
    sig { returns(T.nilable(Tap)) }
    attr_reader :tap

    sig { params(name: String, path: Pathname, alias_path: T.nilable(Pathname), tap: T.nilable(Tap)).void }
    def initialize(name, path, alias_path: nil, tap: nil)
      @name = name
      @path = path
      @alias_path = alias_path
      @tap = tap
    end

    # Gets the formula instance.
    # `alias_path` can be overridden here in case an alias was used to refer to
    # a formula that was loaded in another way.
    def get_formula(spec, alias_path: nil, force_bottle: false, flags: [], ignore_errors: false)
      alias_path ||= self.alias_path
      klass(flags:, ignore_errors:)
        .new(name, path, spec, alias_path:, tap:, force_bottle:)
    end

    def klass(flags:, ignore_errors:)
      load_file(flags:, ignore_errors:) unless Formulary.formula_class_defined_from_path?(path)
      Formulary.formula_class_get_from_path(path)
    end

    private

    def load_file(flags:, ignore_errors:)
      raise FormulaUnavailableError, name unless path.file?

      Formulary.load_formula_from_path(name, path, flags:, ignore_errors:)
    end
  end

  # Loads a formula from a bottle.
  class FromBottleLoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      return if Homebrew::EnvConfig.forbid_packages_from_paths?

      ref = ref.to_s

      new(ref) if HOMEBREW_BOTTLES_EXTNAME_REGEX.match?(ref) && File.exist?(ref)
    end

    def initialize(bottle_name, warn: false)
      @bottle_path = Pathname(bottle_name).realpath
      name, full_name = Utils::Bottles.resolve_formula_names(@bottle_path)
      super name, Formulary.path(full_name)
    end

    def get_formula(spec, force_bottle: false, flags: [], ignore_errors: false, **)
      formula = begin
        contents = Utils::Bottles.formula_contents(@bottle_path, name:)
        Formulary.from_contents(name, path, contents, spec, force_bottle:,
                                flags:, ignore_errors:)
      rescue FormulaUnreadableError => e
        opoo <<~EOS
          Unreadable formula in #{@bottle_path}:
          #{e}
        EOS
        super
      rescue BottleFormulaUnavailableError => e
        opoo <<~EOS
          #{e}
          Falling back to non-bottle formula.
        EOS
        super
      end
      formula.local_bottle_path = @bottle_path
      formula
    end
  end

  # Loads formulae from disk using a path.
  class FromPathLoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      path = case ref
      when String
        Pathname(ref)
      when Pathname
        ref
      else
        return
      end

      return unless path.expand_path.exist?

      return if Homebrew::EnvConfig.forbid_packages_from_paths? &&
                !path.realpath.to_s.start_with?("#{HOMEBREW_CELLAR}/", "#{HOMEBREW_LIBRARY}/Taps/")

      if (tap = Tap.from_path(path))
        # Only treat symlinks in taps as aliases.
        if path.symlink?
          alias_path = path
          path = alias_path.resolved_path
        end
      else
        # Don't treat cache symlinks as aliases.
        tap = Homebrew::API.tap_from_source_download(path)
      end

      return if path.extname != ".rb"

      new(path, alias_path:, tap:)
    end

    sig { params(path: T.any(Pathname, String), alias_path: T.nilable(Pathname), tap: T.nilable(Tap)).void }
    def initialize(path, alias_path: nil, tap: nil)
      path = Pathname(path).expand_path
      name = path.basename(".rb").to_s
      alias_path = alias_path&.expand_path
      alias_dir = alias_path&.dirname

      alias_path = nil if alias_dir != tap&.alias_dir

      super(name, path, alias_path:, tap:)
    end
  end

  # Loads formula from a URI.
  class FromURILoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      return if Homebrew::EnvConfig.forbid_packages_from_paths?

      # Cache compiled regex
      @uri_regex ||= begin
        uri_regex = ::URI::DEFAULT_PARSER.make_regexp
        Regexp.new("\\A#{uri_regex.source}\\Z", uri_regex.options)
      end

      uri = ref.to_s
      return unless uri.match?(@uri_regex)

      uri = URI(uri)
      return unless uri.path
      return unless uri.scheme.present?

      new(uri, from:)
    end

    attr_reader :url

    sig { params(url: T.any(URI::Generic, String), from: T.nilable(Symbol)).void }
    def initialize(url, from: nil)
      @url = url
      @from = from
      uri_path = URI(url).path
      raise ArgumentError, "URL has no path component" unless uri_path

      formula = File.basename(uri_path, ".rb")
      super formula, HOMEBREW_CACHE_FORMULA/File.basename(uri_path)
    end

    def load_file(flags:, ignore_errors:)
      url_scheme = URI(url).scheme
      if ALLOWED_URL_SCHEMES.exclude?(url_scheme)
        raise UnsupportedInstallationMethod,
              "Non-checksummed download of #{name} formula file from an arbitrary URL is unsupported! " \
              "`brew extract` or `brew create` and `brew tap-new` to create a formula file in a tap " \
              "on GitHub instead."
      end
      HOMEBREW_CACHE_FORMULA.mkpath
      FileUtils.rm_f(path)
      Utils::Curl.curl_download url.to_s, to: path
      super
    rescue MethodDeprecatedError => e
      if (match_data = url.match(%r{github.com/(?<user>[\w-]+)/(?<repo>[\w-]+)/}).presence)
        e.issues_url = "https://github.com/#{match_data[:user]}/#{match_data[:repo]}/issues/new"
      end
      raise
    end
  end

  # Loads tapped formulae.
  class FromTapLoader < FormulaLoader
    sig { returns(Tap) }
    attr_reader :tap

    sig { returns(Pathname) }
    attr_reader :path

    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(FormulaLoader))
    }
    def self.try_new(ref, from: nil, warn: false)
      ref = ref.to_s

      return unless (name_tap_type = Formulary.tap_formula_name_type(ref, warn:))

      name, tap, type = name_tap_type
      path = Formulary.find_formula_in_tap(name, tap)

      if type == :alias
        # TODO: Simplify this by making `tap_formula_name_type` return the alias name.
        alias_name = T.must(ref[HOMEBREW_TAP_FORMULA_REGEX, :name]).downcase
      end

      if type == :migration && tap.core_tap? && (loader = FromAPILoader.try_new(name))
        loader
      else
        new(name, path, tap:, alias_name:)
      end
    end

    sig { params(name: String, path: Pathname, tap: Tap, alias_name: T.nilable(String)).void }
    def initialize(name, path, tap:, alias_name: nil)
      alias_path = tap.alias_dir/alias_name if alias_name

      super(name, path, alias_path:, tap:)
      @tap = tap
    end

    def get_formula(spec, alias_path: nil, force_bottle: false, flags: [], ignore_errors: false)
      super
    rescue FormulaUnreadableError => e
      raise TapFormulaUnreadableError.new(tap, name, e.formula_error), "", e.backtrace
    rescue FormulaClassUnavailableError => e
      raise TapFormulaClassUnavailableError.new(tap, name, e.path, e.class_name, e.class_list), "", e.backtrace
    rescue FormulaUnavailableError => e
      raise TapFormulaUnavailableError.new(tap, name), "", e.backtrace
    end

    def load_file(flags:, ignore_errors:)
      super
    rescue MethodDeprecatedError => e
      e.issues_url = tap.issues_url || tap.to_s
      raise
    end
  end

  # Loads a formula from a name, as long as it exists only in a single tap.
  class FromNameLoader < FromTapLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(FormulaLoader))
    }
    def self.try_new(ref, from: nil, warn: false)
      return unless ref.is_a?(String)
      return unless ref.match?(/\A#{HOMEBREW_TAP_FORMULA_NAME_REGEX}\Z/o)

      name = ref

      # If it exists in the default tap, never treat it as ambiguous with another tap.
      if (core_tap = CoreTap.instance).installed? &&
         (core_loader = super("#{core_tap}/#{name}", warn:))&.path&.exist?
        return core_loader
      end

      loaders = Tap.select { |tap| tap.installed? && !tap.core_tap? }
                   .filter_map { |tap| super("#{tap}/#{name}", warn:) }
                   .uniq(&:path)
                   .select { |loader| loader.is_a?(FromAPILoader) || loader.path.exist? }

      case loaders.count
      when 1
        loaders.first
      when 2..Float::INFINITY
        raise TapFormulaAmbiguityError.new(name, loaders)
      end
    end
  end

  # Loads a formula from a formula file in a keg.
  class FromKegLoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      ref = ref.to_s

      return unless (keg_formula = HOMEBREW_PREFIX/"opt/#{ref}/.brew/#{ref}.rb").file?

      new(ref, keg_formula)
    end
  end

  # Loads a formula from a cached formula file.
  class FromCacheLoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      ref = ref.to_s

      return unless (cached_formula = HOMEBREW_CACHE_FORMULA/"#{ref}.rb").file?

      new(ref, cached_formula)
    end
  end

  # Pseudo-loader which will raise a {FormulaUnavailableError} when trying to load the corresponding formula.
  class NullLoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      return if ref.is_a?(URI::Generic)

      new(ref)
    end

    sig { params(ref: T.any(String, Pathname)).void }
    def initialize(ref)
      name = File.basename(ref, ".rb")
      super name, Formulary.core_path(name)
    end

    def get_formula(*)
      raise FormulaUnavailableError, name
    end
  end

  # Load formulae directly from their contents.
  class FormulaContentsLoader < FormulaLoader
    # The formula's contents.
    attr_reader :contents

    def initialize(name, path, contents)
      @contents = contents
      super name, path
    end

    def klass(flags:, ignore_errors:)
      namespace = "FormulaNamespace#{Digest::MD5.hexdigest(contents.to_s)}"
      Formulary.load_formula(name, path, contents, namespace, flags:, ignore_errors:)
    end
  end

  # Load a formula from the API.
  class FromAPILoader < FormulaLoader
    sig {
      params(ref: T.any(String, Pathname, URI::Generic), from: T.nilable(Symbol), warn: T::Boolean)
        .returns(T.nilable(T.attached_class))
    }
    def self.try_new(ref, from: nil, warn: false)
      return if Homebrew::EnvConfig.no_install_from_api?
      return unless ref.is_a?(String)
      return unless (name = ref[HOMEBREW_DEFAULT_TAP_FORMULA_REGEX, :name])
      if !Homebrew::API::Formula.all_formulae.key?(name) &&
         !Homebrew::API::Formula.all_aliases.key?(name) &&
         !Homebrew::API::Formula.all_renames.key?(name)
        return
      end

      alias_name = name

      ref = "#{CoreTap.instance}/#{name}"

      return unless (name_tap_type = Formulary.tap_formula_name_type(ref, warn:))

      name, tap, type = name_tap_type

      alias_name = (type == :alias) ? alias_name.downcase : nil

      new(name, tap:, alias_name:)
    end

    sig { params(name: String, tap: T.nilable(Tap), alias_name: T.nilable(String)).void }
    def initialize(name, tap: nil, alias_name: nil)
      alias_path = CoreTap.instance.alias_dir/alias_name if alias_name

      super(name, Formulary.core_path(name), alias_path:, tap:)
    end

    def klass(flags:, ignore_errors:)
      load_from_api(flags:) unless Formulary.formula_class_defined_from_api?(name)
      Formulary.formula_class_get_from_api(name)
    end

    private

    def load_from_api(flags:)
      Formulary.load_formula_from_api!(name, flags:)
    end
  end

  # Return a {Formula} instance for the given reference.
  # `ref` is a string containing:
  #
  # * a formula name
  # * a formula pathname
  # * a formula URL
  # * a local bottle reference
  #
  # @api internal
  sig {
    params(
      ref:           T.any(Pathname, String),
      spec:          Symbol,
      alias_path:    T.any(NilClass, Pathname, String),
      from:          T.nilable(Symbol),
      warn:          T::Boolean,
      force_bottle:  T::Boolean,
      flags:         T::Array[String],
      ignore_errors: T::Boolean,
    ).returns(Formula)
  }
  def self.factory(
    ref,
    spec = :stable,
    alias_path: nil,
    from: nil,
    warn: false,
    force_bottle: false,
    flags: [],
    ignore_errors: false
  )
    cache_key = "#{ref}-#{spec}-#{alias_path}-#{from}"
    if factory_cached? && platform_cache[:formulary_factory]&.key?(cache_key)
      return platform_cache[:formulary_factory][cache_key]
    end

    formula = loader_for(ref, from:, warn:)
              .get_formula(spec, alias_path:, force_bottle:, flags:, ignore_errors:)

    if factory_cached?
      platform_cache[:formulary_factory] ||= {}
      platform_cache[:formulary_factory][cache_key] ||= formula
    end

    formula
  end

  # Return a {Formula} instance for the given rack.
  #
  # @param spec when nil, will auto resolve the formula's spec.
  # @param alias_path will be used if the formula is found not to be
  #   installed and discarded if it is installed because the `alias_path` used
  #   to install the formula will be set instead.
  sig {
    params(
      rack:         Pathname,
      # Automatically resolves the formula's spec if not specified.
      spec:         T.nilable(Symbol),
      alias_path:   T.any(NilClass, Pathname, String),
      force_bottle: T::Boolean,
      flags:        T::Array[String],
    ).returns(Formula)
  }
  def self.from_rack(rack, spec = nil, alias_path: nil, force_bottle: false, flags: [])
    kegs = rack.directory? ? rack.subdirs.map { |d| Keg.new(d) } : []
    keg = kegs.find(&:linked?) || kegs.find(&:optlinked?) || kegs.max_by(&:scheme_and_version)

    options = {
      alias_path:,
      force_bottle:,
      flags:,
    }.compact

    if keg
      from_keg(keg, *spec, **options)
    else
      factory(rack.basename.to_s, *spec, from: :rack, warn: false, **options)
    end
  end

  # Return whether given rack is keg-only.
  def self.keg_only?(rack)
    Formulary.from_rack(rack).keg_only?
  rescue FormulaUnavailableError, TapFormulaAmbiguityError
    false
  end

  # Return a {Formula} instance for the given keg.
  sig {
    params(
      keg:          Keg,
      # Automatically resolves the formula's spec if not specified.
      spec:         T.nilable(Symbol),
      alias_path:   T.any(NilClass, Pathname, String),
      force_bottle: T::Boolean,
      flags:        T::Array[String],
    ).returns(Formula)
  }
  def self.from_keg(
    keg,
    spec = nil,
    alias_path: nil,
    force_bottle: false,
    flags: []
  )
    tab = keg.tab
    tap = tab.tap
    spec ||= tab.spec

    formula_name = keg.rack.basename.to_s

    options = {
      alias_path:,
      from:         :keg,
      warn:         false,
      force_bottle:,
      flags:,
    }.compact

    f = if tap.nil?
      factory(formula_name, spec, **options)
    else
      begin
        factory("#{tap}/#{formula_name}", spec, **options)
      rescue FormulaUnavailableError
        # formula may be migrated to different tap. Try to search in core and all taps.
        factory(formula_name, spec, **options)
      end
    end
    f.build = tab
    T.cast(f.build, Tab).used_options = Tab.remap_deprecated_options(f.deprecated_options, tab.used_options).as_flags
    f.version.update_commit(keg.version.version.commit) if f.head? && keg.version.head?
    f
  end

  # Return a {Formula} instance directly from contents.
  sig {
    params(
      name:          String,
      path:          Pathname,
      contents:      String,
      spec:          Symbol,
      alias_path:    T.nilable(Pathname),
      force_bottle:  T::Boolean,
      flags:         T::Array[String],
      ignore_errors: T::Boolean,
    ).returns(Formula)
  }
  def self.from_contents(
    name,
    path,
    contents,
    spec = :stable,
    alias_path: nil,
    force_bottle: false,
    flags: [],
    ignore_errors: false
  )
    FormulaContentsLoader.new(name, path, contents)
                         .get_formula(spec, alias_path:, force_bottle:, flags:, ignore_errors:)
  end

  def self.to_rack(ref)
    # If using a fully-scoped reference, check if the formula can be resolved.
    factory(ref) if ref.include? "/"

    # Check whether the rack with the given name exists.
    if (rack = HOMEBREW_CELLAR/File.basename(ref, ".rb")).directory?
      return rack.resolved_path
    end

    # Use canonical name to locate rack.
    (HOMEBREW_CELLAR/canonical_name(ref)).resolved_path
  end

  def self.canonical_name(ref)
    loader_for(ref).name
  rescue TapFormulaAmbiguityError
    # If there are multiple tap formulae with the name of ref,
    # then ref is the canonical name
    ref.downcase
  end

  def self.path(ref)
    loader_for(ref).path
  end

  sig { params(tapped_name: String, warn: T::Boolean).returns(T.nilable([String, Tap, T.nilable(Symbol)])) }
  def self.tap_formula_name_type(tapped_name, warn:)
    return unless (tap_with_name = Tap.with_formula_name(tapped_name))

    tap, name = tap_with_name

    type = nil

    # FIXME: Remove the need to do this here.
    alias_table_key = tap.core_tap? ? name : "#{tap}/#{name}"

    if (possible_alias = tap.alias_table[alias_table_key].presence)
      # FIXME: Remove the need to split the name and instead make
      #        the alias table only contain short names.
      name = T.must(possible_alias.split("/").last)
      type = :alias
    elsif (new_name = tap.formula_renames[name].presence)
      old_name = tap.core_tap? ? name : tapped_name
      name = new_name
      new_name = tap.core_tap? ? name : "#{tap}/#{name}"
      type = :rename
    elsif (new_tap_name = tap.tap_migrations[name].presence)
      new_tap, new_name = Tap.with_formula_name(new_tap_name) || [Tap.fetch(new_tap_name), name]
      new_tap.ensure_installed!
      new_tapped_name = "#{new_tap}/#{new_name}"

      if tapped_name == new_tapped_name
        opoo "Tap migration for #{tapped_name} points to itself, stopping recursion."
      else
        old_name = tap.core_tap? ? name : tapped_name
        return unless (name_tap_type = tap_formula_name_type(new_tapped_name, warn: false))

        name, tap, = name_tap_type

        new_name = new_tap.core_tap? ? name : "#{tap}/#{name}"
        type = :migration
      end
    end

    opoo "Formula #{old_name} was renamed to #{new_name}." if warn && old_name && new_name

    [name, tap, type]
  end

  def self.loader_for(ref, from: nil, warn: true)
    [
      FromBottleLoader,
      FromURILoader,
      FromAPILoader,
      FromTapLoader,
      FromPathLoader,
      FromNameLoader,
      FromKegLoader,
      FromCacheLoader,
      NullLoader,
    ].each do |loader_class|
      if (loader = loader_class.try_new(ref, from:, warn:))
        $stderr.puts "#{$PROGRAM_NAME} (#{loader_class}): loading #{ref}" if debug?
        return loader
      end
    end
  end

  def self.core_path(name)
    find_formula_in_tap(name.to_s.downcase, CoreTap.instance)
  end

  sig { params(name: String, tap: Tap).returns(Pathname) }
  def self.find_formula_in_tap(name, tap)
    filename = if name.end_with?(".rb")
      name
    else
      "#{name}.rb"
    end

    tap.formula_files_by_name.fetch(name, tap.formula_dir/filename)
  end
end
