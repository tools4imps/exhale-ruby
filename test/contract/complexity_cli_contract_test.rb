# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "stringio"
require "exhale/cli"

# `exhale complexity` on the command line, contract/cli/README.md, against a
# throwaway git repository.
class ComplexityCLIContractTest < Minitest::Test
  ORDER = <<~RUBY
    class Order
      def total(lines)
        lines.sum do |line|
          if line.taxed? && line.region
            line.amount * rate(line.region)
          else
            line.amount
          end
        end
      end

      def rate(region) = region.rate
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-complexity-cli")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
    write("app/models/order.rb", ORDER)
    git("add", "-A")
    git("commit", "-q", "-m", "base")
    git("checkout", "-q", "-b", "pr")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    env = { "GIT_AUTHOR_DATE" => "2026-01-01T00:00:00Z", "GIT_COMMITTER_DATE" => "2026-01-01T00:00:00Z" }
    out, status = Open3.capture2e(env, "git", "-C", @dir, *args)
    raise out unless status.success?

    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def exhale(*args)
    out = StringIO.new
    err = StringIO.new
    code = Exhale::CLI.new([*args, "--root", @dir], out: out, err: err).run
    [code, out.string, err.string]
  end

  # One modifier if per point.
  def deep(name, score)
    "class Deep\n  def #{name}(a)\n#{(1..score).map { |k| "    s#{k}(a) if a.r#{k}?\n" }.join}  end\nend\n"
  end

  # Contract: cli/L5
  def test_complexity_runs_the_ratchet_with_its_flags
    write("app/models/deep.rb", deep("go", 9))

    code, out, err = exhale("complexity", "--base", "main", "--format", "json")
    assert_equal 1, code, err
    report = JSON.parse(out)
    assert_equal "complexity", report["check"]
    assert_equal({ "Deep#go" => "introduced", "Order#total" => "unchanged", "Order#rate" => "unchanged" },
                 report["units"].to_h { |u| [u["identity"], u["label"]] })

    code, out, = exhale("complexity", "--base", "main", "--floor", "9", "--format", "json")
    assert_equal 1, code
    assert_equal "new", JSON.parse(out)["units"].find { |u| u["identity"] == "Deep#go" }["label"]

    write("test/models/deep_test.rb", deep("check", 3).sub("class Deep", "class DeepTest"))
    _, out, = exhale("complexity", "--format", "json")
    refute_includes out, "DeepTest#check"
    _, out, = exhale("complexity", "--format", "json", "--include-tests")
    assert_includes out, "DeepTest#check"
  end

  # Contract: cli/L5
  def test_complexity_narrowed_to_a_path_gates_only_there
    write("app/models/deep.rb", deep("go", 9))
    write("lib/calm.rb", "class Calm\n  def x = 1\nend\n")

    code, out, = exhale("complexity", "lib")
    assert_equal 0, code
    assert_match(/narrowed to lib/, out)
    code, = exhale("complexity", "app/models/deep.rb")
    assert_equal 1, code
  end

  # Contract: cli/L5
  def test_explain_prints_every_point_with_its_line_and_reason
    code, out, err = exhale("complexity", "explain", "Order#total")
    assert_equal 0, code, err
    assert_equal <<~TEXT, out
      Order#total  app/models/order.rb:2-10
      score 5, 0 metaprogramming
        line 3     +1  sum block  nesting 0
        line 4     +2  if         nesting 1
        line 4     +1  &&         nesting 1
        line 6     +1  else       nesting 1
    TEXT
  end

  # Contract: cli/L5
  def test_explain_exits_two_when_no_unit_has_that_identity
    code, out, err = exhale("complexity", "explain", "Order#missing")
    assert_equal 2, code
    assert_empty out
    assert_match(/no unit named Order#missing/, err)

    code, _, err = exhale("complexity", "explain")
    assert_equal 2, code
    assert_match(/usage: exhale complexity explain IDENTITY/, err)
  end

  # Contract: cli/L2
  def test_complexity_refuses_unknown_options_formats_and_paths
    assert_equal 2, exhale("complexity", "--threshold", "0.5").first
    assert_equal 2, exhale("complexity", "--floor", "-1").first
    assert_equal 2, exhale("complexity", "--floor", "many").first
    assert_equal 2, exhale("complexity", "--format", "yaml").first
    code, _, err = exhale("complexity", "app/modles")
    assert_equal 2, code
    assert_match(/"app\/modles" is neither a command nor a path/, err)
  end

  # Contract: cli/L3
  def test_complexity_and_its_explain_refuse_a_base_that_names_no_commit
    code, out, err = exhale("complexity", "--base", "nope")
    assert_equal 2, code
    assert_empty out
    assert_match(/--base nope names no commit/, err)
    assert_equal 2, exhale("complexity", "--base=--octopus").first
    assert_equal 2, exhale("complexity", "explain", "Order#total", "--base", "nope").first
    assert_equal 2, exhale("complexity", "explain", "Order#total", "--format", "yaml").first
  end
end
