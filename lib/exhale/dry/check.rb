# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "securerandom"
require "tmpdir"
require "prism"
require "herb"
require_relative "../version"
require_relative "../errors"
require_relative "../git"
require_relative "../source_files"
require_relative "../units"
require_relative "../contract"
require_relative "normalizer"
require_relative "fingerprints"
require_relative "index"
require_relative "matcher"
require_relative "gate"

module Exhale
  module Dry
    DEFAULTS = { threshold: Rational(80, 100), min_lines: 4, min_nodes: 20 }.freeze

    # Everything one tree yields: its units, their index, the Contract read
    # from the same tree, and every match over the threshold.
    class Sweep
      attr_reader :root, :units, :parse_errors, :contract, :resolver, :index, :matches

      def initialize(root, files: nil, include_tests: false, contract_dir: "contract", overrides: {})
        @root = root
        @files = files
        @include_tests = include_tests
        @contract_dir = contract_dir
        @overrides = overrides
      end

      def run
        @units, @parse_errors = Units.read(@root, files: @files, include_tests: @include_tests)
        @contract = Contract.load(@root, dir: @contract_dir)
        @resolver = Contract::Resolver.new(@contract, @units)
        @index = Index.new(entries)
        @matches = Matcher.new(@index, floors: floors, settings_for_pair: method(:settings_for_pair)).matches
        self
      end

      def settings_for_pair(a, b)
        return DEFAULTS.merge(@overrides) unless @overrides.empty?

        exact(@resolver.settings_for_pair(a, b, DEFAULTS))
      end

      private

      def entries
        @units.each_with_index.map do |unit, id|
          tree = Fingerprints.build(Normalizer.normalize(unit))
          Entry.new(id: id, unit: unit, tree: tree, set: tree.digests)
        end
      end

      # Candidates are generated at the loosest floors any primitive asks
      # for; each pair is then judged by its own settings.
      def floors
        all = [DEFAULTS.merge(@overrides)]
        all.concat(@contract.settings.values.map { |settings| DEFAULTS.merge(settings) }) if @overrides.empty?
        { min_lines: all.map { |s| s[:min_lines] }.min, min_nodes: all.map { |s| s[:min_nodes] }.min,
          threshold: all.map { |s| Rational(s[:threshold].to_s) }.min }
      end

      # Contract thresholds arrive as Floats; scores are Rationals. Reading
      # the Float's decimal text keeps 0.75 exactly 3/4.
      def exact(settings)
        settings.merge(threshold: Rational(settings[:threshold].to_s))
      end
    end

    # The duplication check: sweeps the tree on disk, sweeps the merge base
    # for labels, and hands both to the Gate for the verdict.
    class Check
      def initialize(root:, base: nil, include_tests: false, contract_dir: "contract", overrides: {},
                     introduced_only: false, paths: [], cache_dir: nil)
        @root = File.expand_path(root)
        @base_ref = base
        @include_tests = include_tests
        @contract_dir = contract_dir
        @overrides = overrides
        @introduced_only = introduced_only
        @paths = paths
        @cache_dir = cache_dir || File.join(@root, "tmp", "exhale")
        @git = Git.new(@root)
      end

      def run
        base_sha = validate!
        head = Sweep.new(@root, files: (@git.files if @git.repo?), include_tests: @include_tests,
                                contract_dir: @contract_dir, overrides: @overrides).run
        Gate.new(head: head, base: base_sha && base_summary(base_sha), base_sha: base_sha, git: (@git if @git.repo?),
                 changed_lines: base_sha ? @git.changed_lines(base_sha) : {},
                 introduced_only: @introduced_only, paths: @paths, overrides: @overrides).verdict
      end

      # Checks the root and the base before anything is read, and returns
      # the base's SHA (nil when there's no base to label against). The CLI
      # calls it for explain too, so a typo there fails the same way.
      def validate!
        raise Error, "--root #{@root} isn't a directory" unless File.directory?(@root)

        find_base
      end

      private

      # A base the caller named and git can't find is an error: running on
      # unlabeled would hide the mistake. A value that reads as an option
      # never reaches git, where `--octopus` would resolve to HEAD.
      def find_base
        raise Error, "--base #{@base_ref} looks like an option, not a commit" if @base_ref&.start_with?("-")
        raise Error, "--base #{@base_ref} needs a git repository, and #{@root} isn't in one" if @base_ref && !@git.repo?
        return unless @git.repo?

        ref = @base_ref || @git.default_branch_ref
        sha = ref && @git.merge_base(ref)
        raise Error, "--base #{@base_ref} names no commit with a merge base with HEAD" if @base_ref && sha.nil?

        sha
      end

      # What the Gate needs from the base, cached on disk. The key covers
      # everything that changes a base sweep, so a warm cache can never
      # answer differently from a cold run.
      def base_summary(sha)
        path = File.join(@cache_dir, "base-#{sha}-#{VERSION}-n#{Normalizer::VERSION}-#{cache_key(sha)}.json")
        cached = read_cache(path)
        return cached if cached

        summary = Dir.mktmpdir("exhale-base") do |dir|
          files = base_files(sha)
          @git.export_files(sha, files, dir)
          # The same overrides as the head, so a pair that only the flags
          # surface is labeled against a base swept the same way.
          Gate.summarize(Sweep.new(dir, files: files, include_tests: @include_tests, contract_dir: @contract_dir,
                                        overrides: @overrides).run)
        end
        write_cache(path, summary)
        summary
      end

      def cache_key(sha)
        parts = [sha, VERSION, Normalizer::VERSION, Units::Depth::LIMIT, Prism::VERSION, Herb::VERSION, @include_tests,
                 @git.prefix, @contract_dir, @overrides.sort.inspect]
        Digest::SHA256.hexdigest(parts.join("\u0000"))[0, 16]
      end

      # Only the files a sweep can read: source and the Contract.
      def base_files(sha)
        contract = "#{@contract_dir.chomp('/')}/"
        @git.files_at(sha).select { |path| SourceFiles.language(path) || path.start_with?(contract) }
      end

      # Plain JSON, never Marshal: loading a Marshal dump runs whatever it
      # names. Anything at the path that isn't a regular file, or doesn't
      # hold exactly the shape below, is rebuilt.
      def read_cache(path)
        return unless File.lstat(path).file?

        BaseCache.load(File.read(path, encoding: "UTF-8"))
      rescue SystemCallError, IOError
        nil
      end

      # Written beside the target and renamed into place, so a reader never
      # sees half a file. A symlink at the path is left alone: writing
      # through it would overwrite whatever it points at.
      def write_cache(path, summary)
        FileUtils.mkdir_p(File.dirname(path))
        return if File.symlink?(path)

        temp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
        File.open(temp, File::WRONLY | File::CREAT | File::EXCL, 0o644) { |f| f.write(BaseCache.dump(summary)) }
        File.rename(temp, path)
      rescue SystemCallError, IOError
        FileUtils.rm_f(temp) if temp
        nil
      end
    end

    # The base summary as JSON, checked field by field on the way back in.
    module BaseCache
      FORMAT = 1
      RATIONAL = %r{\A(-?\d+)/(\d+)\z}
      KEYS = %w[format clusters structures pairs clause_keys].freeze

      module_function

      def dump(summary)
        JSON.generate(
          "format" => FORMAT,
          "clusters" => summary.clusters.sort.to_h,
          "structures" => summary.structures.sort.to_h { |key, ids| [key, ids.to_a.sort] },
          "pairs" => summary.pairs.map { |row| [*row[0, 2], "#{row[2].numerator}/#{row[2].denominator}", *row[3..]] },
          "clause_keys" => summary.clause_keys.to_a.sort
        )
      end

      # nil for anything that isn't exactly what dump writes.
      def load(text)
        data = JSON.parse(text)
        return unless data.is_a?(Hash) && data.keys.sort == KEYS.sort && data["format"] == FORMAT

        clusters = data["clusters"]
        structures = data["structures"]
        pairs = data["pairs"]
        clause_keys = data["clause_keys"]
        return unless string_hash?(clusters) { |id| id.is_a?(Integer) }
        return unless string_hash?(structures) { |ids| ids.is_a?(Array) && ids.all?(Integer) }
        return unless clause_keys.is_a?(Array) && clause_keys.all?(String)
        return unless pairs.is_a?(Array) && pairs.all? { |row| pair?(row) }

        BaseSummary.new(clusters: clusters, structures: structures, clause_keys: Set.new(clause_keys),
                        pairs: pairs.map { |row| [*row[0, 2], rational(row[2]), *row[3..]] })
      rescue JSON::ParserError, EncodingError
        nil
      end

      def string_hash?(value, &valid)
        value.is_a?(Hash) && value.all? { |key, item| key.is_a?(String) && valid.call(item) }
      end

      def pair?(row)
        row.is_a?(Array) && row.size == 7 && row.all?(String) && RATIONAL.match?(row[2]) &&
          !RATIONAL.match(row[2])[2].to_i.zero?
      end

      def rational(text)
        numerator, denominator = RATIONAL.match(text).captures.map(&:to_i)
        Rational(numerator, denominator)
      end
    end
  end
end
