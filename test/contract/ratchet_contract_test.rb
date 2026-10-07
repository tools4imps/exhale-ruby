# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "exhale/complexity/check"
require "exhale/report"

# The ratchet's obligations, contract/ratchet/README.md, each proved against
# a throwaway git repository: the base is committed on main, the change on
# a branch.
class RatchetContractTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("exhale-ratchet")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args, dir: @dir)
    env = { "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }
    out, status = Open3.capture2e(env, "git", "-C", dir, *args)
    raise out unless status.success?

    out
  end

  def write(path, content, dir: @dir)
    full = File.join(dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
  end

  def branch
    git("checkout", "-q", "-b", "pr")
  end

  # A method that scores exactly `score`: one modifier if per point. Its
  # calls are named after tag, so two methods share a shape only when they
  # share a tag.
  def method(name, score, tag: name)
    lines = (1..score).map { |k| "    #{tag}_step#{k}(a) if a.#{tag}_ready#{k}?\n" }
    "  def #{name}(a)\n#{lines.join}    a\n  end\n"
  end

  def klass(name, *methods)
    "class #{name}\n#{methods.join("\n")}end\n"
  end

  def check(root: @dir, base: "main", **options)
    Exhale::Complexity::Check.new(root: root, base: base, **options).run
  end

  def labels(result)
    result.rows.to_h { |row| [row.unit.identity, row.label] }
  end

  def row(result, identity)
    result.rows.find { |r| r.unit.identity == identity } or flunk "no row for #{identity}"
  end

  # Contract: ratchet/T1
  def test_every_unit_is_scored_at_the_head_and_at_the_merge_base
    write("app/models/order.rb", klass("Order", method("total", 6), method("tax", 2)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("total", 10), method("tax", 2)))
    commit("change")

    result = check
    total = row(result, "Order#total")
    assert_equal [6, 10, :raised], [total.base.score, total.head.score, total.label]
    assert_equal [2, 2, :unchanged], [row(result, "Order#tax").base.score, row(result, "Order#tax").head.score,
                                      row(result, "Order#tax").label]
    assert_equal git("rev-parse", "main").strip, result.base_sha
  end

  # Contract: ratchet/T1
  def test_the_default_base_is_the_merge_base_with_the_default_branch
    write("app/models/order.rb", klass("Order", method("total", 6)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("total", 9)))
    commit("change")
    # main moves on after the branch: the PR is still judged from where it
    # branched.
    git("checkout", "-q", "main")
    write("app/models/order.rb", klass("Order", method("total", 12)))
    commit("main moves on")
    fork = git("merge-base", "main", "pr").strip
    git("checkout", "-q", "pr")

    result = check(base: nil)
    assert_equal fork, result.base_sha
    assert_equal [6, 9, :raised], [row(result, "Order#total").base.score, row(result, "Order#total").head.score,
                                   row(result, "Order#total").label]
  end

  # Contract: ratchet/T1
  def test_with_no_git_nothing_is_compared_and_units_over_the_floor_warn
    Dir.mktmpdir("exhale-no-git") do |dir|
      write("app/models/order.rb", klass("Order", method("total", 12), method("tax", 2)), dir: dir)
      result = check(root: dir, base: nil)
      assert_equal 0, result.exit_code
      assert_nil result.base_sha
      assert_equal({ "Order#total" => :warning, "Order#tax" => :scored }, labels(result))
      assert_match(/not a git repository, so nothing is compared/, result.notes.first)
      text = Exhale::Report.render(result, "text")
      assert_match(/OVER THE FLOOR  Order#total  12 \(floor 8\)/, text)
      assert_match(/clean/, text.lines.first)
    end
  end

  # Contract: ratchet/T1
  def test_with_no_merge_base_nothing_is_compared
    git("checkout", "-q", "-b", "trunk")
    write("app/models/order.rb", klass("Order", method("total", 12)))
    commit("only a trunk")

    result = check(base: nil)
    assert_equal 0, result.exit_code
    assert_equal({ "Order#total" => :warning }, labels(result))
    assert_match(/no merge base found, so nothing is compared/, result.notes.first)
  end

  # Contract: ratchet/T2
  def test_a_unit_matches_the_base_unit_with_its_identity_wherever_it_moved
    write("app/models/order.rb", klass("Order", method("total", 9)))
    commit("base")
    branch
    git("rm", "-q", "app/models/order.rb")
    write("app/models/billing/order.rb", klass("Order", method("total", 9, tag: "other")))
    commit("move and rewrite")

    total = row(check, "Order#total")
    assert_equal [:identity, :unchanged], [total.match, total.label]
    assert_equal "app/models/order.rb", total.base.unit.path
  end

  # Contract: ratchet/T2
  def test_a_renamed_or_moved_unit_keeps_its_history_by_shape
    write("app/models/order.rb", klass("Order", method("total", 9)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order"))
    write("app/models/invoice.rb", klass("Invoice", method("sum", 10, tag: "total")))
    commit("rename and raise")

    result = check
    sum = row(result, "Invoice#sum")
    assert_equal [:shape, "Order#total", :raised], [sum.match, sum.base.unit.identity, sum.label]
    assert_operator sum.similarity, :>=, Rational(80, 100)
    refute(result.rows.any? { |r| r.label == :gone })
    assert_match(/was Order#total at app\/models\/order.rb:2-/, Exhale::Report.render(result, "text"))
  end

  # Contract: ratchet/T2
  def test_a_shape_under_the_threshold_doesnt_match
    write("app/models/order.rb", klass("Order", method("total", 9)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("sum", 9, tag: "other")))
    commit("a different method")

    assert_equal({ "Order#sum" => :introduced, "Order#total" => :gone }, labels(check))
  end

  # Contract: ratchet/T2
  def test_ties_go_to_the_base_unit_first_in_path_and_line_order_and_each_matches_once
    write("app/models/b.rb", klass("B", method("copy", 9, tag: "same")))
    write("app/models/a.rb", klass("A", method("first", 9, tag: "same"), method("second", 9, tag: "same")))
    commit("base")
    branch
    write("app/models/a.rb", klass("A"))
    write("app/models/b.rb", klass("B"))
    write("app/models/c.rb", klass("C", method("one", 9, tag: "same"), method("two", 9, tag: "same"),
                                   method("three", 9, tag: "same"), method("four", 9, tag: "same")))
    commit("renames")

    result = check
    matched = %w[C#one C#two C#three].map { |identity| row(result, identity).base.unit.identity }
    assert_equal %w[A#first A#second B#copy], matched
    assert_equal :introduced, row(result, "C#four").label
  end

  # Contract: ratchet/T3
  def test_a_rise_that_ends_over_the_floor_fails_and_a_unit_that_didnt_rise_passes
    write("app/models/order.rb", klass("Order", method("raised", 7), method("rose", 3), method("high", 20),
                                       method("higher", 14)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("raised", 9), method("rose", 8), method("high", 20),
                                       method("higher", 13), method("fresh", 9), method("small", 8)))
    commit("change")

    result = check
    assert_equal({ "Order#raised" => :raised, "Order#rose" => :rose, "Order#high" => :unchanged,
                   "Order#higher" => :contracted, "Order#fresh" => :introduced, "Order#small" => :new },
                 labels(result))
    assert_equal %w[Order#raised Order#fresh], result.rows.select(&:failing?).map { |r| r.unit.identity }
    assert_equal 1, result.exit_code
  end

  # Contract: ratchet/T4
  def test_falls_are_contracted_and_lost_units_are_gone
    write("app/models/order.rb", klass("Order", method("total", 12), method("old", 4)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("total", 5)))
    commit("shrink")

    result = check
    assert_equal({ "Order#total" => :contracted, "Order#old" => :gone }, labels(result))
    assert_equal 0, result.exit_code
    assert_equal "1 contracted", Exhale::Report.render(result, "text").lines.last.strip
  end

  # Contract: ratchet/T4
  def test_splitting_a_method_passes_when_every_new_piece_ends_under_the_floor
    write("app/models/order.rb", klass("Order", method("total", 12)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("total", 4), method("lines", 6, tag: "l"),
                                       method("tax", 8, tag: "t")))
    commit("split")
    result = check
    assert_equal 0, result.exit_code, labels(result).inspect
    # The total rose from 12 to 18, and the total never counts.
    assert_equal 18, result.rows.sum { |r| r.head.score }

    write("app/models/order.rb", klass("Order", method("total", 3), method("lines", 9, tag: "l")))
    assert_equal({ "Order#total" => :contracted, "Order#lines" => :introduced }, labels(check))
  end

  # Contract: ratchet/T5
  def test_the_floor_defaults_to_eight
    write("app/models/order.rb", klass("Order"))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("eight", 8), method("nine", 9)))
    result = check
    assert_equal({ "Order#eight" => :new, "Order#nine" => :introduced }, labels(result))
    assert_equal [8, 8], result.rows.map(&:floor)
  end

  # Contract: ratchet/T5
  def test_a_primitive_sets_its_own_floor_in_complexity_md
    write("contract/billing/README.md", "# Billing\n\n```covers\nBilling\n```\n")
    write("contract/billing/complexity.md", "# Billing\n\n```settings\nfloor: 3\n```\n")
    commit("base")
    branch
    write("app/models/billing/order.rb", "module Billing\n#{klass('Order', method('total', 4))}end\n")
    write("app/models/cart.rb", klass("Cart", method("total", 4, tag: "cart")))
    result = check
    assert_equal({ "Billing::Order#total" => :introduced, "Cart#total" => :new }, labels(result))
    assert_equal 3, row(result, "Billing::Order#total").floor
  end

  # Contract: ratchet/T5
  def test_the_floor_flag_changes_the_report_and_never_the_verdict
    write("app/models/order.rb", klass("Order", method("total", 9)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("total", 10), method("small", 4, tag: "s")))

    loose = check(floor: 20)
    assert_equal({ "Order#total" => :rose, "Order#small" => :new }, labels(loose))
    assert_equal [20, 1], [loose.floor, loose.exit_code]
    assert(loose.notes.any? { |note| note.include?("--floor 20 overrides the Contract for this report only") })

    write("app/models/order.rb", klass("Order", method("total", 9), method("small", 4, tag: "s")))
    strict = check(floor: 2)
    assert_equal({ "Order#total" => :unchanged, "Order#small" => :introduced }, labels(strict))
    assert_equal 0, strict.exit_code
  end

  CEILING = <<~MD
    # Billing

    ## The rate table stays one method

    Splitting it scatters the regions across files.

    ```ceiling
    max: 14
    Order#rates
    ```
  MD

  # Contract: ratchet/T6
  def test_a_ceiling_keeps_its_units_up_to_its_max
    write("contract/billing/complexity.md", CEILING)
    write("app/models/order.rb", klass("Order", method("rates", 9)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("rates", 14)))
    result = check
    rates = row(result, "Order#rates")
    assert_equal [:kept, 14], [rates.label, rates.ceiling.max]
    assert_equal "The rate table stays one method Splitting it scatters the regions across files.", rates.ceiling.reason
    assert_equal 0, result.exit_code
    kept = JSON.parse(Exhale::Report.render(result, "json"))["units"].find { |u| u["identity"] == "Order#rates" }
    assert_equal({ "path" => "contract/billing/complexity.md", "line" => 7, "max" => 14 }, kept["ceiling"])
    assert_match(/KEPT  Order#rates  9 -> 14 \(ceiling 14\)  contract\/billing\/complexity.md:7 "The rate table stays one method"/,
                 Exhale::Report.render(result, "text"))

    write("app/models/order.rb", klass("Order", method("rates", 15)))
    result = check
    assert_equal [:raised, 1], [row(result, "Order#rates").label, result.exit_code]
  end

  # Contract: ratchet/T6
  def test_a_ceiling_keeps_a_new_unit_too
    write("contract/billing/complexity.md", CEILING)
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("rates", 12)))
    result = check
    assert_equal [:kept, 0], [row(result, "Order#rates").label, result.exit_code]
  end

  # Contract: ratchet/T6
  def test_a_stale_ceiling_and_one_that_names_no_unit_fail
    write("contract/billing/complexity.md", CEILING)
    write("app/models/order.rb", klass("Order", method("rates", 12)))
    commit("base")
    branch
    write("app/models/order.rb", klass("Order", method("rates", 8)))
    result = check
    assert_equal :contracted, row(result, "Order#rates").label
    assert_equal ["contract/billing/complexity.md:7"], result.clause_errors.map { |e| "#{e.path}:#{e.line}" }
    assert_match(/stale ceiling/, result.clause_errors.first.message)
    assert_equal 1, result.exit_code

    write("app/models/order.rb", klass("Order", method("prices", 12)))
    result = check
    assert_equal ["contract/billing/complexity.md:9"], result.clause_errors.map { |e| "#{e.path}:#{e.line}" }
    assert_match(/names no unit: Order#rates/, result.clause_errors.first.message)
    assert_equal 1, result.exit_code
  end

  # Contract: ratchet/T7
  def test_exit_codes
    write("app/models/order.rb", klass("Order", method("total", 9)))
    commit("base")
    branch
    assert_equal 0, check.exit_code

    write("app/models/order.rb", klass("Order", method("total", 10)))
    assert_equal 1, check.exit_code

    write("app/models/order.rb", klass("Order", method("total", 9)))
    write("contract/billing/complexity.md", "```settings\nfloor: none\n```\n")
    assert_equal 1, check.exit_code

    write("contract/billing/complexity.md", "# nothing\n")
    write("app/models/broken.rb", "class Broken\n  def x(\nend\n")
    result = check
    assert_equal 2, result.exit_code
    assert_equal ["app/models/broken.rb"], result.parse_errors.map(&:path)

    FileUtils.rm(File.join(@dir, "app/models/broken.rb"))
    error = assert_raises(Exhale::Error) { check(base: "nope") }
    assert_match(/--base nope names no commit/, error.message)
    assert_raises(Exhale::Error) { check(base: "--octopus") }
  end

  # Contract: ratchet/T7
  def test_a_file_that_doesnt_parse_at_the_base_doesnt_stop_the_run
    write("app/models/order.rb", "class Order\n  def total(\nend\n")
    commit("broken base")
    branch
    write("app/models/order.rb", klass("Order", method("total", 4)))
    result = check
    assert_equal [0, :new], [result.exit_code, row(result, "Order#total").label]
    assert(result.notes.any? { |note| note.include?("app/models/order.rb doesn't parse at the base") })
  end
end
