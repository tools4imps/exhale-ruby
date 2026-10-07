# frozen_string_literal: true

require "optparse"
require_relative "version"
require_relative "errors"
require_relative "report"
require_relative "units"
require_relative "dry/check"
require_relative "complexity/check"

module Exhale
  # exhale [dry] [PATH...] [options]
  # exhale dry explain A B
  # exhale complexity [PATH...] [options]
  # exhale complexity explain UNIT
  #
  # Exit codes: 0 pass, 1 the gate failed, 2 exhale couldn't run.
  class CLI
    CHECKS = %w[dry complexity].freeze
    BANNERS = {
      "dry" => "usage: exhale [dry] [PATH...] [options]\n       exhale dry explain IDENTITY IDENTITY",
      "complexity" => "usage: exhale complexity [PATH...] [options]\n       exhale complexity explain IDENTITY"
    }.freeze

    def initialize(argv, out: $stdout, err: $stderr)
      @argv = argv.dup
      @out = out
      @err = err
      @options = { root: Dir.pwd, format: "text", include_tests: false, contract_dir: "contract",
                   overrides: {}, introduced_only: false, base: nil, cache_dir: nil }
    end

    def run
      @check = CHECKS.include?(@argv.first) ? @argv.shift : "dry"
      return explain(@argv.drop(1)) if @argv.first == "explain"

      paths = parser.parse(@argv)
      return 2 unless valid_format?

      paths = narrowing(paths)
      return 2 unless paths

      result = @check == "dry" ? dry(paths) : complexity(paths)
      @out.print Report.render(result, @options[:format])
      result.exit_code
    rescue OptionParser::ParseError, ArgumentError => e
      @err.puts "exhale: #{e.message}"
      @err.puts parser.banner
      2
    rescue Error => e
      @err.puts "exhale: #{e.message}"
      2
    end

    private

    def dry(paths)
      Dry::Check.new(root: @options[:root], base: @options[:base], include_tests: @options[:include_tests],
                     contract_dir: @options[:contract_dir], overrides: @options[:overrides],
                     introduced_only: @options[:introduced_only], paths: paths, cache_dir: @options[:cache_dir]).run
    end

    def complexity(paths)
      Complexity::Check.new(root: @options[:root], base: @options[:base], floor: @options[:floor],
                            include_tests: @options[:include_tests], contract_dir: @options[:contract_dir],
                            paths: paths).run
    end

    def parser
      @parser ||= OptionParser.new do |o|
        o.banner = BANNERS.fetch(@check)
        o.on("--base REF", "Compare with the merge base of REF and HEAD (default: the default branch)") do |v|
          @options[:base] = v
        end
        @check == "dry" ? dry_options(o) : complexity_options(o)
        common_options(o)
      end
    end

    def complexity_options(o)
      o.on("--floor N", Integer, "Scores at or under N never fail (overrides the Contract for this report)") do |v|
        raise OptionParser::InvalidArgument, "--floor #{v}" if v.negative?

        @options[:floor] = v
      end
    end

    def dry_options(o)
      o.on("--threshold N", Float, "Minimum score, 0 to 1 (overrides the Contract; the run won't gate)") do |v|
        @options[:overrides][:threshold] = Rational(v.to_s)
      end
      o.on("--min-lines N", Integer, "Minimum source lines (overrides the Contract; the run won't gate)") do |v|
        @options[:overrides][:min_lines] = v
      end
      o.on("--min-nodes N", Integer, "Minimum normalized nodes (overrides the Contract; the run won't gate)") do |v|
        @options[:overrides][:min_nodes] = v
      end
      o.on("--introduced-only", "On-ramp: gate only on introduced and shifted findings") do
        @options[:introduced_only] = true
      end
      o.on("--cache DIR", "Cache directory (default tmp/exhale/)") { |v| @options[:cache_dir] = v }
    end

    def common_options(o)
      o.on("--format F", "text, json or edn (default text)") { |v| @options[:format] = v }
      o.on("--include-tests", "Include spec/ and test/") { @options[:include_tests] = true }
      o.on("--contract DIR", "The Contract's root (default contract/)") { |v| @options[:contract_dir] = v }
      o.on("--root DIR", "Repository root (default: the current directory)") { |v| @options[:root] = v }
      o.on("-v", "--version", "Print the version") do
        @out.puts "exhale #{VERSION}"
        exit 0
      end
      o.on("-h", "--help", "Print this help") do
        @out.puts o
        exit 0
      end
    end

    # Every positional argument has to be a path that exists under the root.
    # A typo like `exhale dyr` must fail loudly, never narrow the run to
    # nothing and pass.
    def narrowing(args)
      root = File.expand_path(@options[:root])
      args.map do |arg|
        full = File.expand_path(arg, root)
        unless File.exist?(full) && (full == root || full.start_with?("#{root}/"))
          @err.puts "exhale: #{arg.inspect} is neither a command nor a path under #{root}"
          return nil
        end
        full == root ? "." : full.delete_prefix("#{root}/")
      end
    end

    def valid_format?
      return true if Report::FORMATS.include?(@options[:format])

      @err.puts "exhale: unknown format #{@options[:format].inspect} (use text, json or edn)"
      false
    end

    # explain checks --format, --root and --base the way a run does, so a
    # flag that would fail CI fails here too.
    def explain(args)
      args = parser.parse(args)
      arity = @check == "dry" ? 2 : 1
      unless args.size == arity
        @err.puts "usage: #{BANNERS.fetch(@check).lines.last.strip}"
        return 2
      end
      return 2 unless valid_format?

      @check == "dry" ? dry_explain(args) : complexity_explain(args.first)
    end

    # Prints one unit's score and every point that earned it.
    def complexity_explain(identity)
      Complexity::Check.new(root: @options[:root], base: @options[:base]).validate!
      root = File.expand_path(@options[:root])
      git = Git.new(root)
      units, _errors = Units.read(root, files: (git.files if git.repo?), include_tests: @options[:include_tests])
      unit = units.find { |u| u.language == :ruby && u.identity == identity }
      return missing(identity) unless unit

      @out.print Report.explain(Complexity::Scored.of(unit))
      0
    end

    def missing(identity)
      @err.puts "exhale: no unit named #{identity}"
      2
    end

    # Prints two units' normalized trees and their score, for tuning.
    def dry_explain(args)
      Dry::Check.new(root: @options[:root], base: @options[:base], cache_dir: @options[:cache_dir]).validate!
      root = File.expand_path(@options[:root])
      git = Git.new(root)
      sweep = Dry::Sweep.new(root, files: (git.files if git.repo?), include_tests: @options[:include_tests],
                                   contract_dir: @options[:contract_dir]).run
      a, b = args.map { |identity| sweep.index.entries.find { |e| e.unit.identity == identity } }
      absent = args.zip([a, b]).find { |_, entry| entry.nil? }
      return missing(absent[0]) if absent

      [a, b].each do |entry|
        @out.puts "#{entry.unit.identity}  #{entry.unit.path}:#{entry.unit.start_line}-#{entry.unit.end_line}"
        print_shape(Dry::Normalizer.normalize(entry.unit), 1)
        @out.puts
      end
      shared = a.set & b.set
      @out.puts "score #{Report.score(sweep.index.score(a.set, a.total, b.set, b.total))}, " \
                "#{shared.size} shared of #{(a.set | b.set).size} fingerprints"
      0
    end

    def print_shape(shape, depth)
      label = shape.label ? " #{shape.label}" : ""
      @out.puts "#{'  ' * depth}#{shape.kind}#{label}"
      shape.children.each { |child| print_shape(child, depth + 1) }
    end
  end
end
