# typed: strict
# frozen_string_literal: true

module UnpackStrategy
  # Strategy for unpacking LHa archives.
  class Lha
    include UnpackStrategy

    sig { override.returns(T::Array[String]) }
    def self.extensions
      [".lha", ".lzh"]
    end

    sig { override.params(path: Pathname).returns(T::Boolean) }
    def self.can_extract?(path)
      path.magic_number.match?(/\A..-(lh0|lh1|lz4|lz5|lzs|lh\\40|lhd|lh2|lh3|lh4|lh5)-/n)
    end

    sig { returns(T.nilable(T::Array[Formula])) }
    def dependencies
      @dependencies ||= T.let([Formula["lha"]], T.nilable(T::Array[Formula]))
    end

    private

    sig { override.params(unpack_dir: Pathname, basename: Pathname, verbose: T::Boolean).void }
    def extract_to_dir(unpack_dir, basename:, verbose:)
      system_command! "lha",
                      args:    ["xq2w=#{unpack_dir}", path],
                      env:     { "PATH" => PATH.new(Formula["lha"].opt_bin, ENV.fetch("PATH")) },
                      verbose:
    end
  end
end
