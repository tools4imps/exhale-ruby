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

    # rows are narrowed to the run's paths. floor is the default floor the
    # report was judged with: the Contract's, or --floor's.
    Result = Struct.new(:rows, :clause_errors, :parse_errors, :base_sha, :notes, :exit_code, :floor,
                        keyword_init: true)

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
        errors = contract.errors + @resolver.errors + stale(contract, head)

        judge = lambda do |floor_for|
          narrow(Ratchet.new(head: head, base: base, floor_for: floor_for, ceiling_for: ceilings).rows)
        end
        verdict = judge.call(method(:contract_floor))
        rows = @floor ? judge.call(->(_unit) { @floor }) : verdict
        Result.new(rows: rows, clause_errors: errors, parse_errors: parse_errors, base_sha: base_sha, notes: notes,
                   exit_code: exit_code(parse_errors, verdict, errors), floor: @floor || DEFAULT_FLOOR)
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
          files = @git.files_at(sha).select { |path| SourceFiles.language(path) == :ruby }
          @git.export_files(sha, files, dir)
          units, errors = Units.read(dir, files: files, include_tests: @include_tests)
          errors.each { |e| @notes << "#{e.path} doesn't parse at the base, so its units count as new" }
          units.map { |unit| Scored.of(unit) }
        end
      end

      def no_base_note(base_sha)
        return if base_sha

        why = @git.repo? ? "no merge base found" : "not a git repository"
        @notes.unshift("#{why}, so nothing is compared; units over the floor are warnings")
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

      # A ceiling is stale once nothing it names sits over the floor.
      def stale(contract, head)
        scores = head.each_with_object({}.compare_by_identity) { |scored, map| map[scored.unit] = scored.score }
        ceilings(contract).filter_map do |clause|
          next unless stale?(clause, scores)

          ContractError.new(clause.path, clause.line,
                            "stale ceiling: nothing it names scores over the floor; delete it")
        end
      end

      def stale?(clause, scores)
        units = clause.references.flat_map { |ref| @resolver.units_for(ref) }.select { |unit| scores.key?(unit) }
        units.any? && units.none? { |unit| scores[unit] > contract_floor(unit) }
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
