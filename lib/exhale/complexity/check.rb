# frozen_string_literal: true

require "tmpdir"
require_relative "../errors"
require_relative "../git"
require_relative "../source_files"
require_relative "../units"
require_relative "../contract"
require_relative "../dry/check"
require_relative "cognitive"
require_relative "ratchet"

module Exhale
  module Complexity
    DEFAULT_FLOOR = 8

    # rows are narrowed to the run's paths. floor is the floor the report
    # was judged with: the default, or --floor's. floors are the primitives
    # that set their own, by name. contract_failing are the rows that fail
    # under the Contract's floors and pass under --floor's.
    Result = Struct.new(:rows, :clause_errors, :parse_errors, :base_sha, :notes, :exit_code, :floor, :floors,
                        :contract_failing, keyword_init: true)

    # The complexity check: scores every Ruby unit at the head and at the
    # merge base, and hands both to the Ratchet.
    class Check
      def initialize(root:, base: nil, floor: nil, include_tests: false, contract_dir: "contract", paths: [])
        @root = File.expand_path(root)
        @base_ref = base
        @floor = floor
        @include_tests = include_tests
        @contract_dir = contract_dir
        @paths = paths
        @git = Git.new(@root)
        @notes = []
      end

      def run
        base_sha = validate!
        units, parse_errors = Units.read(@root, files: (@git.files if @git.repo?), include_tests: @include_tests)
        contract = Contract.load(@root, dir: @contract_dir, check: :complexity)
        @resolver = Contract::Resolver.new(contract, units)
        head = units.select { |unit| unit.language == :ruby }.map { |unit| Scored.of(unit) }
        base = base_scores(base_sha) if base_sha
        no_base_note(base_sha)
        ceilings = ceiling_lookup(contract)
        errors = contract.errors + @resolver.errors + ceiling_errors(contract, head)

        judge = lambda do |floor_for|
          narrow(Ratchet.new(head: head, base: base, floor_for: floor_for, ceiling_for: ceilings).rows)
        end
        verdict = judge.call(method(:contract_floor))
        rows = @floor ? judge.call(->(_unit) { @floor }) : verdict
        Result.new(rows: rows, clause_errors: errors, parse_errors: parse_errors, base_sha: base_sha, notes: notes,
                   exit_code: exit_code(parse_errors, verdict, errors), floor: @floor || DEFAULT_FLOOR,
                   floors: floors(contract), contract_failing: contract_failing(verdict, rows))
      end

      # The SHA of the merge base, or nil when there's none to compare with.
      # A --base git can't find is an error, the same as for dry.
      def validate!
        Dry::Check.new(root: @root, base: @base_ref).validate!
      end

      private

      def contract_floor(unit)
        @resolver.settings_for(unit, { floor: DEFAULT_FLOOR })[:floor]
      end

      def base_scores(sha)
        Dir.mktmpdir("exhale-complexity") do |dir|
          files = @git.files_at(sha).select do |path|
            SourceFiles.language(path) == :ruby || path == SourceFiles::CONFIG_FILE
          end
          @git.export_files(sha, files, dir)
          units, errors = Units.read(dir, files: files, include_tests: @include_tests)
          errors.each { |e| @notes << "#{e.path} doesn't parse at the base, so its units count as new" }
          units.map { |unit| Scored.of(unit) }
        end
      end

      def no_base_note(base_sha)
        return if base_sha

        advice = "; pass --base REF to compare" if @git.repo? && !@git.default_branch_ref
        @notes.unshift("#{no_base_reason}, so nothing is compared; units over the floor are warnings#{advice}")
      end

      def no_base_reason
        return "not a git repository" unless @git.repo?
        return "no merge base found" if @git.default_branch_ref

        *first, last = Git::DEFAULT_CANDIDATES
        "no default branch found (origin/HEAD, #{first.join(', ')} or #{last})"
      end

      # Both lists hold the same units in the same order.
      def contract_failing(verdict, rows)
        verdict.zip(rows).filter_map { |contract, shown| contract if contract.failing? && !shown.failing? }
      end

      # Under --floor every primitive takes it, so none has its own.
      def floors(contract)
        return {} if @floor

        contract.settings.filter_map { |name, settings| [name, settings[:floor]] if settings.key?(:floor) }.to_h
      end

      def notes
        notes = @notes.dup
        if @floor
          notes << "--floor #{@floor} overrides the Contract for this report only; " \
                   "the exit code keeps the Contract's floors"
        end
        notes << "narrowed to #{@paths.join(', ')}: only units there are reported and gated" unless @paths.empty?
        notes
      end

      # unit => the clause of its most specific ceiling reference. A tie
      # takes the lower max, then the clause written first.
      def ceiling_lookup(contract)
        best = {}.compare_by_identity
        ceiling_ranks(contract).sort_by(&:first).each { |_, unit, clause| best[unit] = clause }
        ->(unit) { best[unit] }
      end

      def ceiling_ranks(contract)
        ceilings(contract).each_with_index.flat_map do |clause, index|
          clause.references.flat_map do |ref|
            @resolver.units_for(ref).map { |unit| [[ref.specificity, -clause.max, -index], unit, clause] }
          end
        end
      end

      def ceilings(contract)
        contract.clauses.select { |clause| clause.kind == :ceiling }
      end

      def ceiling_errors(contract, head)
        scores = head.each_with_object({}.compare_by_identity) { |scored, map| map[scored.unit] = scored.score }
        ceilings(contract).filter_map do |clause|
          problem = ceiling_problem(clause, scores)
          ContractError.new(clause.path, clause.line, problem) if problem
        end
      end

      # A ceiling has to name a scored unit, and is stale once nothing it
      # names sits over the floor. A reference that names nothing at all is
      # already the resolver's error.
      def ceiling_problem(clause, scores)
        named = clause.references.flat_map { |ref| @resolver.units_for(ref) }
        return if named.empty?

        scored = named.select { |unit| scores.key?(unit) }
        return "ceiling names no scored unit; only methods and DSL bodies are scored" if scored.empty?
        return if scored.any? { |unit| scores[unit] > contract_floor(unit) }

        "stale ceiling: nothing it names scores over the floor; delete it"
      end

      def narrow(rows)
        return rows if @paths.empty?

        rows.select { |row| @paths.any? { |p| p == "." || row.unit.path == p || row.unit.path.start_with?("#{p}/") } }
      end

      def exit_code(parse_errors, verdict, errors)
        return 2 unless parse_errors.empty?

        verdict.any?(&:failing?) || !errors.empty? ? 1 : 0
      end
    end
  end
end
