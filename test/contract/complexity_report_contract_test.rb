# frozen_string_literal: true

require "test_helper"
require "json"
require "exhale/units"
require "exhale/complexity/check"
require "exhale/report"

# The complexity report's obligations, contract/report/README.md, on results
# built by hand so every byte is known.
class ComplexityReportContractTest < Minitest::Test
  HEAD = <<~RUBY
    class Order
      def total(lines)
        lines.each do |line|
          if line.taxed?
            line.tax if line.region && line.rate
          end
        end
        send(:audit)
      end

      def fresh(a)
        a ? 1 : 2
      end

      def calm = 1
    end
  RUBY

  BASE = <<~RUBY
    class Order
      def total(lines)
        lines.each { |line| line.tax if line.taxed? }
      end

      def calm
        @calm ||= 1 if ready?
      end

      def old(a) = a
    end
  RUBY

  def scored(source, path)
    Exhale::Units::Ruby.extract(source, path).to_h { |u| [u.identity, Exhale::Complexity::Scored.of(u)] }
  end

  def result
    head = scored(HEAD, "app/models/order.rb")
    base = scored(BASE, "app/models/order.rb")
    row = ->(label, h, b, floor: 2) { Exhale::Complexity::Row.new(label: label, head: h, base: b, floor: floor) }
    rows = [
      row.call(:raised, head["Order#total"], base["Order#total"]),
      row.call(:introduced, head["Order#fresh"], nil),
      row.call(:contracted, head["Order#calm"], base["Order#calm"]),
      Exhale::Complexity::Row.new(label: :gone, base: base["Order#old"])
    ]
    rows.first.match = :identity
    Exhale::Complexity::Result.new(rows: rows, clause_errors: [], parse_errors: [], base_sha: "a" * 40, notes: [],
                                   exit_code: 1, floor: 2, floors: {}, contract_failing: [])
  end

  # Contract: report/R5
  def test_text_names_each_failing_unit_with_its_scores_and_worst_lines
    assert_equal <<~TEXT, Exhale::Report.render(result, "text")
      exhale complexity: 3 units, 1 raised, 1 introduced, 1 contracted, 1 gone, failing   base aaaaaaa   floor 2

      RAISED  Order#total  3 -> 8 (floor 2)
        app/models/order.rb:2-9
        line 5     +4   if, &&
        line 4     +2   if
        line 3     +1   each block
        line 8     +1   send
        hint      bring it back to 3 or less: pull the worst lines into named methods

      INTRODUCED  Order#fresh  1 (floor 2)
        app/models/order.rb:11-13
        line 12    +1   ternary
        hint      split it until every piece scores 2 or less

      1 contracted
    TEXT
  end

  # Contract: report/R5
  def test_text_lists_kept_units_with_their_ceiling
    kept = result
    clause = Exhale::Contract::Clause.new("billing", :ceiling, "contract/billing/complexity.md", 7, "Rates stay whole",
                                          "", [], "k", 9)
    kept.rows = [Exhale::Complexity::Row.new(label: :kept, head: kept.rows[0].head, base: kept.rows[0].base, floor: 2,
                                             ceiling: clause)]
    kept.exit_code = 0
    assert_equal <<~TEXT, Exhale::Report.render(kept, "text")
      exhale complexity: 1 units, 1 kept, clean   base aaaaaaa   floor 2

      KEPT  Order#total  3 -> 8 (ceiling 9)  contract/billing/complexity.md:7 "Rates stay whole"

      0 contracted
    TEXT
  end

  # Contract: report/R2
  def test_the_header_counts_labels_and_errors_and_says_clean_only_on_exit_zero
    passing = result
    passing.rows = passing.rows.drop(2)
    passing.exit_code = 0
    assert_equal "exhale complexity: 1 units, 1 contracted, 1 gone, clean   base aaaaaaa   floor 2",
                 Exhale::Report.render(passing, "text").lines.first.chomp

    passing.clause_errors = [Exhale::ContractError.new("contract/p/complexity.md", 3, "stale ceiling")]
    passing.exit_code = 1
    text = Exhale::Report.render(passing, "text")
    assert_match(/1 contract error, failing/, text.lines.first)
    passing.parse_errors = [Exhale::ParseError.new("app/x.rb", 2, "unexpected end")]
    assert_match(/1 contract error, 1 parse error, failing/, Exhale::Report.render(passing, "text").lines.first)
    assert_includes text, "CONTRACT  contract/p/complexity.md:3: stale ceiling"
  end

  # Contract: report/R6
  def test_json_carries_every_scored_unit_with_its_score_metaprogramming_and_label
    report = JSON.parse(Exhale::Report.render(result, "json"))
    assert_equal [Exhale::VERSION, "complexity", "a" * 40, 1, 2],
                 report.values_at("exhale", "check", "base", "exit_code", "floor")
    units = report["units"].map { |u| u.values_at("identity", "label", "score", "base_score", "metaprogramming") }
    assert_equal [["Order#total", "raised", 8, 3, 1], ["Order#fresh", "introduced", 1, nil, 0],
                  ["Order#calm", "contracted", 0, 1, 0], ["Order#old", "gone", nil, 0, 0]], units
    assert_nil report["units"][1]["base"]
    total = report["units"].first
    assert_equal({ "identity" => "Order#total", "path" => "app/models/order.rb", "start_line" => 2, "end_line" => 4 },
                 total["base"])
    assert_equal({ "line" => 8, "construct" => "send", "nesting" => 0, "increment" => 1, "meta" => true },
                 total["points"].last)
    assert_equal({ "raised" => 1, "introduced" => 1, "contracted" => 1, "gone" => 1 }, report["counts"])
  end

  # Contract: report/R6
  def test_edn_writes_crappers_entry_shape
    assert_equal <<~EDN, Exhale::Report.render(result, "edn")
      {:entries
       [{:name "total", :namespace "Order", :complexity 8}
        {:name "fresh", :namespace "Order", :complexity 1}
        {:name "calm", :namespace "Order", :complexity 0}]}
    EDN
  end

  # Contract: report/R4
  def test_the_same_complexity_result_renders_the_same
    %w[text json edn].each do |format|
      assert_equal Exhale::Report.render(result, format), Exhale::Report.render(result, format)
    end
  end

  def test_explain_lists_every_point
    total = scored(HEAD, "app/models/order.rb")["Order#total"]
    assert_equal <<~TEXT, Exhale::Report.explain(total)
      Order#total  app/models/order.rb:2-9
      score 8, 1 metaprogramming
        line 3     +1  each block  nesting 0
        line 4     +2  if          nesting 1
        line 5     +3  if          nesting 2
        line 5     +1  &&          nesting 2
        line 8     +1  send        nesting 0
    TEXT
  end

  def test_an_unknown_format_is_refused
    assert_raises(ArgumentError) { Exhale::Report.render(result, "yaml") }
  end
end
