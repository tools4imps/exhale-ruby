# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "dry/normalizer"
require_relative "complexity/check"

module Exhale
  # Renders a duplication check's result as text for the agent doing the
  # exhale, JSON for tools, or EDN in the shape dryer writes to
  # .metrics/dry.edn. A complexity check's result renders the same three
  # ways, its EDN in the shape crapper writes.
  module Report
    FORMATS = %w[text json edn].freeze
    COMPLEXITY_LABELS = %i[raised introduced kept warning contracted gone].freeze
    TOP_LINES = 5
    LABELS = { introduced: "INTRODUCED", shifted: "SHIFTED", already_there: "ALREADY THERE", found: "FOUND" }.freeze

    module_function

    def render(result, format)
      raise ArgumentError, "unknown format #{format.inspect}" unless FORMATS.include?(format)

      text, json, edn = if result.is_a?(Complexity::Result) then [ComplexityText, ComplexityJson, ComplexityEdn]
                        else [Text, Json, Edn]
                        end
      case format
      when "text" then text.new(result).render
      when "json" then JSON.pretty_generate(json.new(result).to_h)
      else edn.new(result).render
      end
    end

    def counts(result)
      counts = Hash.new(0)
      result.findings.each { |f| counts[f.klass] += 1 }
      counts[:kept] = result.kept.size
      counts[:contracted] = result.contracted.size
      counts
    end

    def kind_name(kind, location)
      kind == :fragment ? "fragment, #{location.lines} lines" : kind.to_s
    end

    def score(value)
      value.to_f.round(2)
    end

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

    class Text
      def initialize(result)
        @result = result
        @out = []
      end

      def render
        @out << header
        @result.notes.each { |note| @out << "note: #{note}" }
        @result.findings.each { |f| finding(f) }
        @result.kept.each { |k| kept(k) }
        contracted
        errors
        "#{@out.join("\n")}\n"
      end

      private

      def header
        counts = Report.counts(@result)
        parts = %i[introduced shifted already_there found kept contracted].filter_map do |key|
          "#{counts[key]} #{key.to_s.tr('_', ' ')}" if counts[key].positive?
        end
        parts << plural(@result.clause_errors.size, "contract error") unless @result.clause_errors.empty?
        parts << plural(@result.parse_errors.size, "parse error") unless @result.parse_errors.empty?
        parts << (@result.exit_code.zero? ? "clean" : "failing") if parts.empty?
        base = @result.base_sha ? "   base #{@result.base_sha[0, 7]}" : ""
        "exhale dry: #{parts.join(', ')}#{base}"
      end

      def plural(count, noun)
        "#{count} #{noun}#{'s' unless count == 1}"
      end

      def finding(f)
        @out << ""
        @out << "#{LABELS.fetch(f.klass)}  #{Report.score(f.score)}  #{Report.kind_name(f.kind, f.copy)}"
        rows = [[f.touched.include?(f.copy) ? "new" : "copy", f.copy, nil]]
        f.others.each { |l, s| rows << ["existing", l, f.others.size > 1 ? Report.score(s) : nil] }
        table(rows)
        @out << "  hint      #{f.hint}"
      end

      def kept(k)
        @out << ""
        flag = k.new_clause ? "  NEW CLAUSE, review its reason" : ""
        @out << "KEPT  #{Report.score(k.score)}  #{k.clause.path}:#{k.clause.line} \"#{k.clause.heading}\"#{flag}"
        table([["side", k.a, nil], ["side", k.b, nil]])
      end

      def table(rows)
        width = rows.map { |_, l, _| place(l).size }.max
        ident = rows.map { |_, l, _| l.unit.identity.size }.max
        rows.each do |label, l, s|
          line = "  #{label.ljust(9)} #{place(l).ljust(width)}  #{l.unit.identity.ljust(ident)}"
          line += "  #{s}" if s
          @out << line.rstrip
        end
      end

      def place(location)
        "#{location.path}:#{location.start_line}-#{location.end_line}"
      end

      def contracted
        return if @result.contracted.empty?

        @out << ""
        @out << "CONTRACTED"
        @result.contracted.first(20).each do |c|
          @out << "  #{c.a} no longer matches #{c.b} (#{Report.score(c.score)} at base)"
        end
        more = @result.contracted.size - 20
        @out << "  and #{more} more" if more.positive?
      end

      def errors
        return if @result.clause_errors.empty? && @result.parse_errors.empty?

        @out << ""
        @result.clause_errors.each { |e| @out << "CONTRACT  #{e.message}" }
        @result.parse_errors.each { |e| @out << "PARSE     #{e.message}" }
      end
    end

    class Json
      def initialize(result)
        @result = result
      end

      def to_h
        {
          "exhale" => VERSION,
          "check" => "dry",
          "normalizer" => Dry::Normalizer::VERSION,
          "base" => @result.base_sha,
          "exit_code" => @result.exit_code,
          "counts" => Report.counts(@result).transform_keys(&:to_s),
          "notes" => @result.notes,
          "findings" => @result.findings.map { |f| finding(f) },
          "kept" => @result.kept.map { |k| kept(k) },
          "contracted" => @result.contracted.map { |c| { "a" => c.a, "b" => c.b, "score" => Report.score(c.score) } },
          "contract_errors" => @result.clause_errors.map { |e| error(e) },
          "parse_errors" => @result.parse_errors.map { |e| error(e) }
        }
      end

      private

      def finding(f)
        {
          "class" => f.klass.to_s, "score" => Report.score(f.score), "kind" => f.kind.to_s,
          "copy" => location(f.copy, f.touched),
          "existing" => f.others.map { |l, s| location(l, f.touched).merge("score" => Report.score(s)) },
          "hint" => f.hint, "payoff" => f.payoff, "primitive" => f.primitive
        }
      end

      def kept(k)
        {
          "score" => Report.score(k.score), "a" => location(k.a, []), "b" => location(k.b, []),
          "clause" => { "path" => k.clause.path, "line" => k.clause.line, "heading" => k.clause.heading },
          "new_clause" => k.new_clause
        }
      end

      def location(l, touched)
        { "path" => l.path, "start_line" => l.start_line, "end_line" => l.end_line, "identity" => l.unit.identity,
          "nodes" => l.size, "touched" => touched.include?(l) }
      end

      def error(e)
        { "path" => e.path, "line" => e.line, "message" => e.message }
      end
    end

    # The candidates list dryer writes, one entry per copy and existing pair.
    class Edn
      def initialize(result)
        @result = result
      end

      def render
        rows = @result.findings.flat_map do |f|
          f.others.map { |l, s| candidate(f.copy, l, s) }
        end
        "{:candidates\n [#{rows.join("\n  ")}]}\n"
      end

      private

      def candidate(left, right, score)
        "{:score #{score.to_f.round(12)}\n   :language #{left.unit.language.to_s.inspect}\n   " \
          ":left #{side(left)}\n   :right #{side(right)}\n   :left-nodes #{left.size}\n   :right-nodes #{right.size}}"
      end

      def side(l)
        "{:file #{l.path.inspect}, :start-line #{l.start_line}, :end-line #{l.end_line}}"
      end
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
