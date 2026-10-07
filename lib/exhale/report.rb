# frozen_string_literal: true

require "json"
require_relative "version"
require_relative "dry/normalizer"

module Exhale
  # Renders a duplication check's result as text for the agent doing the
  # exhale, JSON for tools, or EDN in the shape dryer writes to
  # .metrics/dry.edn. A complexity check's result renders from
  # report/complexity.rb.
  module Report
    FORMATS = %w[text json edn].freeze
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
  end
end

require_relative "report/complexity"
