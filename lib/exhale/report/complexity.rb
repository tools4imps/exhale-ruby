# frozen_string_literal: true

require "json"
require_relative "../version"
require_relative "../complexity/check"

module Exhale
  module Report
    COMPLEXITY_LABELS = %i[raised introduced kept warning contracted gone].freeze
    TOP_LINES = 5

    module_function

    # One unit's score with every point, for `exhale complexity explain`.
    def explain(scored)
      unit = scored.unit
      out = ["#{unit.identity}  #{unit.path}:#{unit.start_line}-#{unit.end_line}",
             "score #{scored.score}, #{scored.meta} metaprogramming"]
      width = scored.points.map { |p| p.construct.size }.max.to_i
      scored.points.each do |p|
        out << "  line #{p.line.to_s.ljust(5)} +#{p.increment}  #{p.construct.ljust(width)}  nesting #{p.nesting}"
      end
      "#{out.join("\n")}\n"
    end

    def complexity_counts(result)
      counts = Hash.new(0)
      result.rows.each { |row| counts[row.label] += 1 }
      counts
    end

    # [[line, points earned there, constructs]], worst first.
    def worst_lines(points)
      points.group_by(&:line).map { |line, at| [line, at.sum(&:increment), at.map(&:construct).uniq] }
            .sort_by { |line, total, _| [-total, line] }.first(TOP_LINES)
    end

    # Shares the duplication report's error lines and places.
    class ComplexityText < Text
      HEADINGS = { raised: "RAISED", introduced: "INTRODUCED", warning: "OVER THE FLOOR" }.freeze
      CONTRACT_FAILING = "FAILS UNDER THE CONTRACT'S FLOORS"

      def render
        @out << header
        @result.notes.each { |note| @out << "note: #{note}" }
        @result.rows.select { |row| HEADINGS.key?(row.label) }.sort_by { |row| order(row) }.each { |row| unit(row) }
        # Under --floor these units pass in the report but fail the run.
        @result.contract_failing.each { |row| unit(row, CONTRACT_FAILING) }
        kept
        errors
        @out << ""
        @out << "#{Report.complexity_counts(@result)[:contracted]} contracted"
        "#{@out.join("\n")}\n"
      end

      private

      def header
        counts = Report.complexity_counts(@result)
        parts = ["#{@result.rows.count(&:head)} units"]
        COMPLEXITY_LABELS.each { |label| parts << "#{counts[label]} #{label}" if counts[label].positive? }
        parts << plural(@result.clause_errors.size, "contract error") unless @result.clause_errors.empty?
        parts << plural(@result.parse_errors.size, "parse error") unless @result.parse_errors.empty?
        parts << (@result.exit_code.zero? ? "clean" : "failing")
        base = @result.base_sha ? "   base #{@result.base_sha[0, 7]}" : ""
        floors = @result.floors.map { |name, floor| ", #{name} #{floor}" }.join
        "exhale complexity: #{parts.join(', ')}#{base}   floor #{@result.floor}#{floors}"
      end

      def order(row)
        [HEADINGS.keys.index(row.label), -row.head.score, row.unit.path, row.unit.start_line]
      end

      def unit(row, heading = HEADINGS.fetch(row.label))
        head = row.head
        @out << ""
        @out << "#{heading}  #{head.unit.identity}  #{scores(row)}"
        @out << "  #{place(head.unit)}"
        @out << "  was #{row.base.unit.identity} at #{place(row.base.unit)}" if row.match == :shape
        Report.worst_lines(head.points).each do |line, total, constructs|
          @out << "  line #{line.to_s.ljust(5)} +#{total.to_s.ljust(3)} #{constructs.join(', ')}"
        end
        @out << "  hint      #{hint(row)}"
      end

      def scores(row)
        limit = row.ceiling ? "ceiling #{row.ceiling.max}" : "floor #{row.floor}"
        from = row.base ? "#{row.base.score} -> " : ""
        "#{from}#{row.head.score} (#{limit})"
      end

      def hint(row)
        limit = row.ceiling ? [row.ceiling.max, row.floor].max : row.floor
        case row.label
        when :raised
          "bring it back to #{[row.base.score, limit].max} or less: pull the worst lines into named methods"
        when :introduced then "split it until every piece scores #{limit} or less"
        else "it was already over the floor; nothing is compared without a base"
        end
      end

      def kept
        @result.rows.select { |row| row.label == :kept }.each do |row|
          clause = row.ceiling
          @out << ""
          @out << "KEPT  #{row.head.unit.identity}  #{scores(row)}  #{clause.path}:#{clause.line} \"#{clause.heading}\""
        end
      end
    end

    class ComplexityJson
      def initialize(result)
        @result = result
      end

      def to_h
        {
          "exhale" => VERSION,
          "check" => "complexity",
          "base" => @result.base_sha,
          "floor" => @result.floor,
          "floors" => @result.floors,
          "exit_code" => @result.exit_code,
          "counts" => Report.complexity_counts(@result).transform_keys(&:to_s),
          "notes" => @result.notes,
          "units" => @result.rows.map { |row| row(row) },
          "contract_failing" => @result.contract_failing.map { |row| row.unit.identity },
          "contract_errors" => @result.clause_errors.map { |e| error(e) },
          "parse_errors" => @result.parse_errors.map { |e| error(e) }
        }
      end

      private

      def row(row)
        side(row.head || row.base).merge(
          "label" => row.label.to_s, "score" => row.head&.score, "base_score" => row.base&.score,
          "base" => row.head && row.base ? side(row.base).slice("identity", "path", "start_line", "end_line") : nil,
          "match" => row.match&.to_s, "similarity" => row.similarity&.to_f&.round(2), "floor" => row.floor,
          "ceiling" => row.ceiling && row.ceiling.to_h.slice(:path, :line, :max).transform_keys(&:to_s)
        )
      end

      def side(scored)
        unit = scored.unit
        { "identity" => unit.identity, "kind" => unit.kind.to_s, "path" => unit.path,
          "start_line" => unit.start_line, "end_line" => unit.end_line, "metaprogramming" => scored.meta,
          "points" => scored.points.map { |p| p.to_h.transform_keys(&:to_s) } }
      end

      def error(e)
        { "path" => e.path, "line" => e.line, "message" => e.message }
      end
    end

    # The entries crapper writes, so uml-viewer can read them.
    class ComplexityEdn
      def initialize(result)
        @result = result
      end

      def render
        rows = @result.rows.select(&:head).map do |row|
          unit = row.head.unit
          "{:name #{unit.name.inspect}, :namespace #{unit.namespace.inspect}, :complexity #{row.head.score}}"
        end
        "{:entries\n [#{rows.join("\n  ")}]}\n"
      end
    end
  end
end
