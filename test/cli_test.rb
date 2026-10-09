# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "stringio"
require "exhale/cli"

class CLITest < Minitest::Test
  INVOICE = <<~RUBY
    class Invoice
      def totals(lines)
        subtotal = lines.sum { |line| line.amount * line.quantity }
        tax = subtotal * rate_for(region)
        discount = lines.select(&:discounted?).sum(&:discount)
        { subtotal: subtotal, tax: tax, discount: discount, total: subtotal + tax - discount }
      end
    end
  RUBY

  RECEIPT = <<~RUBY
    class Receipt
      def totals(items)
        net = items.sum { |item| item.amount * item.quantity }
        levy = net * rate_for(region)
        off = items.select(&:discounted?).sum(&:discount)
        { subtotal: net, tax: levy, discount: off, total: net + levy - off }
      end
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-cli")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    out, status = Open3.capture2e("git", "-C", @dir, *args)
    raise out unless status.success?

    out
  end

  def write(path, content)
    full = File.join(@dir, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, content)
  end

  def commit(message)
    git("add", "-A")
    git("commit", "-q", "-m", message)
  end

  def exhale(*args, cache: true)
    out = StringIO.new
    err = StringIO.new
    argv = [*args, "--root", @dir]
    argv += ["--cache", File.join(@dir, "tmp", "exhale")] if cache
    code = Exhale::CLI.new(argv, out: out, err: err).run
    [code, out.string, err.string]
  end

  # --version and --help exit the process, so the test catches the exit.
  def exhale_exiting(*args)
    out = StringIO.new
    err = StringIO.new
    error = assert_raises(SystemExit) { Exhale::CLI.new(args, out: out, err: err).run }
    [error.status, out.string, err.string]
  end

  def commit_a_tiny_copy
    write("app/models/a.rb", "class A\n  def x(v)\n    v.call(1) + v.call(2)\n  end\nend\n")
    write("app/models/b.rb", "class B\n  def y(w)\n    w.call(1) + w.call(2)\n  end\nend\n")
    commit("a tiny copy")
  end

  def introduce_a_copy
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)
  end

  # Value: protects=the exit-code contract CI depends on (0 clean, 1 introduced duplication) and the text report reaching stdout; fails_when=CLI returns the wrong code, drops result.exit_code, or prints nothing; why_new=no test drives Exhale::CLI at all; seam=none
  # Contract: gate/G2
  # Contract: cli/L1
  def test_exit_one_with_a_text_report_for_an_introduced_copy_and_zero_when_clean
    introduce_a_copy
    code, out, err = exhale("--base", "main")

    assert_equal 1, code, err
    assert_match(/\Aexhale dry: 1 introduced/, out)
    assert_match(/^INTRODUCED  [\d.]+  method$/, out)
    assert_match(%r{new +app/models/receipt\.rb:\d+-\d+ +Receipt#totals}, out)

    git("checkout", "-q", "main")
    FileUtils.rm_f(File.join(@dir, "app/models/receipt.rb"))
    code, out, = exhale("dry", "--base", "main")

    assert_equal 0, code
    assert_match(/\Aexhale dry: clean/, out)
  end

  # Value: protects=exit 2 ("exhale couldn't run") for bad format, unknown option, and unparseable source, never mistaken for a pass or a duplication failure; fails_when=any of the three returns 0 or 1, or a bad format still runs the check; why_new=the rescue/valid_format? paths in cli.rb and the parse-error exit rule have no test; seam=none
  # Contract: gate/G2
  # Contract: cli/L2
  def test_exit_two_for_bad_format_unknown_option_and_parse_errors
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")

    code, out, err = exhale("--format", "yaml")
    assert_equal 2, code
    assert_empty out
    assert_equal "exhale: unknown format \"yaml\" (use text, json or edn)\n", err
    refute File.exist?(File.join(@dir, "tmp", "exhale")), "a bad format must stop before the check sweeps or caches"

    code, _, err = exhale("--bogus")
    assert_equal 2, code
    assert_match(/exhale: invalid option: --bogus/, err)
    assert_match(/usage: exhale/, err)

    write("app/models/broken.rb", "class Broken\n  def x(\nend\n")
    commit("broken")
    code, out, = exhale("--base", "main")
    assert_equal 2, code
    assert_match(/PARSE .*broken\.rb/, out)
  end

  # Value: protects=a repository can exempt non-Ruby generator templates with .exhale.yml, at both the head and merge base; fails_when=the head or exported base ignores the config and a template parse error prevents the gate from running; why_new=SourceFiles receives the config from disk, but base sweeps export an explicit file list; seam=none
  # Contract: source/S7
  def test_exhale_config_ignores_files_at_the_head_and_merge_base
    write(".exhale.yml", "ignore:\n  - lib/generators/**/*\n")
    write("lib/generators/service/templates/service.rb", "class <%= class_name %>; end\n")
    write("app/models/user.rb", "class User; end\n")
    commit("ignore generator templates")
    git("checkout", "-q", "-b", "feature")

    %w[dry complexity].each do |check|
      code, out, err = exhale(check, "--base", "main", cache: check == "dry")

      assert_equal 0, code, err
      refute_match(/PARSE/, out)
    end
  end

  # Value: protects=flag overrides report but never gate, and a narrowed run gates on the findings inside its paths; fails_when=overrides gate, or a narrowed run passes while a finding sits inside its paths; why_new=the narrowing rule changed after review proved a typo could switch the gate off; seam=none
  # Contract: gate/G6
  # Contract: cli/L4
  def test_overrides_never_gate_and_a_narrowed_run_gates_on_its_paths
    introduce_a_copy
    File.write(File.join(@dir, "app", "unrelated.rb"), "class Unrelated\n  def call = 1\nend\n")

    code, out, = exhale("--base", "main", "--threshold", "0.5")
    assert_equal 0, code
    assert_match(/note: flags override the Contract, so this run doesn't gate/, out)
    assert_match(/1 introduced/, out)

    code, out, = exhale("--base", "main", "app/models/receipt.rb")
    assert_equal 1, code
    assert_match(%r{note: narrowed to app/models/receipt\.rb: only findings there are reported and gated}, out)

    code, out, = exhale("--base", "main", "app/unrelated.rb")
    assert_equal 0, code
    assert_match(/\Aexhale dry: clean/, out)
  end

  # Value: protects=a positional argument that isn't an existing path fails loudly; fails_when=a typo like `exhale dyr` narrows the run to nothing and exits 0; why_new=review proved typos switched the gate off; seam=none
  # Contract: cli/L2
  def test_a_typo_is_an_error_and_never_a_clean_run
    introduce_a_copy

    %w[dyr check app/nope].each do |arg|
      code, _out, err = exhale("--base", "main", arg)
      assert_equal 2, code, "#{arg} should exit 2"
      assert_match(/is neither a command nor a path/, err)
    end
  end

  # Value: protects=`.` names the whole root and a path outside the root is refused; fails_when=`.` is rejected as a typo, or `..` narrows the run to a directory exhale never swept; why_new=narrowing's root comparison had no test; seam=none
  # Contract: cli/L2
  def test_dot_narrows_to_the_root_and_a_path_outside_it_exits_two
    introduce_a_copy

    code, out, = exhale("--base", "main", ".")
    assert_equal 1, code
    assert_match(/^note: narrowed to \.: only findings there are reported and gated$/, out)

    code, out, err = exhale("--base", "main", "..")
    assert_equal 2, code
    assert_empty out
    assert_match(/exhale: "\.\." is neither a command nor a path under /, err)
  end

  # Value: protects=test code stays out of the run unless --include-tests asks for it; fails_when=the default compares test/ files, or the flag doesn't bring them in; why_new=the include_tests default and flag had no CLI test; seam=none
  # Contract: source/S3
  def test_tests_are_compared_only_with_include_tests
    write("test/support/invoice_fixture.rb", INVOICE)
    write("test/support/receipt_fixture.rb", RECEIPT)
    commit("two copies under test/")

    code, out, = exhale("--base", "main")
    assert_equal 0, code
    assert_match(/\Aexhale dry: clean/, out)

    code, out, = exhale("--base", "main", "--include-tests")
    assert_equal 1, code
    assert_match(/\Aexhale dry: 1 already there/, out)
    assert_match(%r{test/support/receipt_fixture\.rb:\d+-\d+ +Receipt#totals}, out)
  end

  # Value: protects=--min-lines and --min-nodes each lower their own floor, report under it, and never gate; fails_when=either flag is dropped, or one flag sets the other's floor; why_new=neither flag had a test; seam=none
  # Contract: cli/L4
  def test_min_lines_and_min_nodes_each_lower_their_own_floor
    commit_a_tiny_copy

    [[], %w[--min-lines 1], %w[--min-nodes 1]].each do |flags|
      code, out, = exhale("--base", "main", *flags)
      assert_equal 0, code, flags.inspect
      assert_match(/\Aexhale dry: clean/, out, flags.inspect)
    end

    code, out, = exhale("--base", "main", "--min-lines", "1", "--min-nodes", "1")
    assert_equal 0, code
    assert_match(/^note: flags override the Contract, so this run doesn't gate$/, out)
    assert_match(%r{^  copy      app/models/b\.rb:2-4  B#y$}, out)
  end

  # Value: protects=the --introduced-only on-ramp is reachable from the command line and off by default; fails_when=the flag is dropped, doesn't switch the on-ramp on, or the default run skips already-there findings; why_new=the gate tests drive Check directly, never the flag; seam=none
  # Contract: gate/G7
  def test_introduced_only_is_off_by_default_and_the_flag_turns_it_on
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("a copy already on main")

    code, out, = exhale("--base", "main")
    assert_equal 1, code
    assert_match(/\Aexhale dry: 1 already there/, out)

    code, out, = exhale("--base", "main", "--introduced-only")
    assert_equal 0, code
    assert_match(/^note: introduced-only on-ramp/, out)
  end

  # Value: protects=--contract reads the Contract from another directory, and the default reads contract/; fails_when=the flag is dropped and the clause that keeps the pair is never read; why_new=--contract had no test; seam=none
  # Contract: cli/L4
  def test_contract_flag_reads_the_contract_from_another_directory
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    write("docs/contract/billing/duplication.md", "## Kept on purpose\n\n```parallel\nInvoice\nReceipt\n```\n")
    commit("a kept copy")

    code, = exhale("--base", "main")
    assert_equal 1, code

    code, out, = exhale("--base", "main", "--contract", "docs/contract")
    assert_equal 0, code, out
    assert_match(%r{^KEPT  [\d.]+  docs/contract/billing/duplication\.md:\d+ "Kept on purpose"$}, out)
  end

  # Value: protects=with no --cache the base sweep is cached under tmp/exhale/ in the root; fails_when=the default cache directory is lost and the check crashes or writes elsewhere; why_new=every other test passes --cache; seam=none
  def test_the_base_sweep_is_cached_under_tmp_exhale_by_default
    introduce_a_copy

    code, = exhale("--base", "main", cache: false)

    assert_equal 1, code
    assert_equal 1, Dir[File.join(@dir, "tmp", "exhale", "base-*.json")].size
  end

  # Value: protects=--version and --help print and exit 0; fails_when=either flag is dropped and exits 2 as an unknown option, or prints nothing; why_new=neither flag had a test; seam=none
  def test_version_and_help_print_and_exit_zero
    status, out, err = exhale_exiting("--version")
    assert_equal 0, status
    assert_equal "exhale #{Exhale::VERSION}\n", out
    assert_empty err

    status, out, = exhale_exiting("--help")
    assert_equal 0, status
    assert_match(/\Ausage: exhale \[dry\] \[PATH\.\.\.\] \[options\]$/, out)
    assert_match(/--include-tests/, out)
  end

  # Value: protects=explain prints each named unit, in the order given, with its place and normalized tree; fails_when=explain picks the wrong unit, swaps the pair, or prints only the score; why_new=the explain contract test reads only the score line; seam=none
  # Contract: cli/L1
  def test_explain_prints_both_units_in_order_with_their_trees
    commit_a_tiny_copy

    code, out, err = exhale("dry", "explain", "B#y", "A#x")

    assert_equal 0, code, err
    tree = <<~TREE
      def_node
        parameters_node
          :local
        statements_node
          call_node +
            call_node call
              :local
              arguments_node
                :literal
            arguments_node
              call_node call
                :local
                arguments_node
                  :literal
    TREE
    indented = tree.gsub(/^/, "  ")
    assert_equal "B#y  app/models/b.rb:2-4\n#{indented}\nA#x  app/models/a.rb:2-4\n#{indented}\n" \
                 "score 1.0, 9 shared of 9 fingerprints\n", out
  end

  # Value: protects=explain with the wrong number of units, or a unit that doesn't exist, exits 2 and says why; fails_when=explain crashes, or exits 0 on a typo; why_new=explain's error paths had no test; seam=none
  def test_explain_without_two_known_units_exits_two
    commit_a_tiny_copy

    code, out, err = exhale("dry", "explain", "A#x")
    assert_equal [2, "", "usage: exhale dry explain IDENTITY IDENTITY\n"], [code, out, err]

    code, out, err = exhale("dry", "explain", "A#x", "C#z")
    assert_equal [2, "", "exhale: no unit named C#z\n"], [code, out, err]
  end
end
