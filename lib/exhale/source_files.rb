# frozen_string_literal: true

require "yaml"
require_relative "errors"

module Exhale
  # Lists the Ruby and ERB files exhale analyses.
  module SourceFiles
    CONFIG_FILE = ".exhale.yml"
    EXCLUDED_ROOTS = %w[vendor node_modules tmp log coverage public storage bin].freeze
    EXCLUDED_PREFIXES = ["app/assets/builds/"].freeze
    # Schema, migrations and settings, at the root and in each engine or pack
    # of a monorepo.
    EXCLUDED_DIRS = %r{\A(?:(?:engines|packs|components|gems)/[^/]+/)?(?:db|config)/}
    # A generator's header: a comment line that opens with the marker. A
    # comment that only mentions generated code somewhere doesn't count.
    GENERATED = %r{
      \A\s*(?:<%\#|\#|//)\s*
      (?:this\ file\ is\ auto-?generated|this\ file\ is\ automatically\ generated|auto-?generated\ by
        |generated\ by\b.*\bdo\ not\ edit|do\ not\ edit|code\ generated\b.*\bdo\ not\ edit)
    }xi
    # Enough of a file to hold its first five lines.
    HEADER_BYTES = 64 * 1024

    module_function

    def list(root, files: nil, include_tests: false)
      candidates = files ? files.map(&:to_s) : walk(root)
      ignored = ignored_globs(root)
      candidates
        .select { |path| language(path) && path_allowed?(path, include_tests) }
        .reject { |path| ignored?(path, ignored) }
        .sort
        .uniq
        .reject { |path| linked?(root, path) }
        .select { |path| File.exist?(File.join(root, path)) }
        .reject { |path| generated?(File.join(root, path)) }
        .map { |path| [path, language(path)] }
    end

    def language(path)
      case path
      when /\.rb\z/ then :ruby
      # Herb reads HTML with ERB in it. Text, JSON and prompt templates that
      # happen to use ERB aren't HTML, so they aren't compared.
      when /\.html(\+[\w-]+)?\.erb\z/, /\.turbo_stream\.erb\z/ then :erb
      end
    end

    def walk(root)
      Dir.glob("**/*", base: root).select do |path|
        full = File.join(root, path)
        File.file?(full) && !File.symlink?(full)
      end
    end

    # A symlink, or a path under a symlinked directory, points outside the
    # tree exhale was asked to read, or at a file it already reads.
    def linked?(root, path)
      segments = path.split("/")
      segments.each_index.any? { |i| File.symlink?(File.join(root, *segments[0..i])) }
    end

    def path_allowed?(path, include_tests)
      segments = path.split("/")
      return false if segments.any? { |s| s.start_with?(".") }
      return false if EXCLUDED_ROOTS.include?(segments.first) || path.match?(EXCLUDED_DIRS)
      return false if EXCLUDED_PREFIXES.any? { |p| path.start_with?(p) }

      include_tests || !test_path?(path, segments)
    end

    def ignored?(path, globs)
      globs.any? { |glob| File.fnmatch?(glob, path, File::FNM_PATHNAME) }
    end

    def ignored_globs(root)
      path = File.join(root, CONFIG_FILE)
      return [] unless File.exist?(path) || File.symlink?(path)
      raise Error, "#{CONFIG_FILE} must not be a symlink" if File.symlink?(path)
      return [] unless File.file?(path)

      config = YAML.safe_load(File.read(path, encoding: "UTF-8"), aliases: false)
      return [] if config.nil?
      raise Error, "#{CONFIG_FILE} must contain a mapping" unless config.is_a?(Hash)

      ignore = config.fetch("ignore", [])
      raise Error, "#{CONFIG_FILE} ignore must be a list of glob patterns" unless ignore.is_a?(Array) && ignore.all?(String)

      ignore
    rescue Psych::Exception => error
      raise Error, "#{CONFIG_FILE} could not be parsed: #{error.message}"
    end

    def test_path?(path, segments)
      segments[0..-2].any? { |s| %w[spec test].include?(s) } || path.end_with?("_spec.rb", "_test.rb")
    end

    # Only a generator's header takes a file off the list. A file exhale
    # can't read, or that isn't valid UTF-8, stays on it so the sweep reports
    # it as a parse error; dropping it here would let it through the gate
    # unread.
    def generated?(full)
      head = File.open(full, "rb") { |file| file.read(HEADER_BYTES) }.to_s
      head.force_encoding(Encoding::UTF_8).scrub.each_line.first(5).any? { |line| line.match?(GENERATED) }
    rescue SystemCallError
      false
    end
  end
end
