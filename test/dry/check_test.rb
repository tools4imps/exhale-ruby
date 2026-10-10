# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"
require "open3"
require "exhale/dry/check"
require "exhale/report"

class CheckTest < Minitest::Test
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

  UNRELATED = <<~RUBY
    class Shipment
      def label
        [carrier.code, tracking_number].join("-")
      end
    end
  RUBY

  def setup
    @dir = Dir.mktmpdir("exhale-check")
    git("init", "-q", "-b", "main")
    git("config", "user.name", "Test")
    git("config", "user.email", "test@example.com")
    write(".gitignore", "tmp/\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def git(*args)
    date = @date || "2026-01-01T00:00:00Z"
    env = { "GIT_AUTHOR_DATE" => date, "GIT_COMMITTER_DATE" => date }
    out, status = Open3.capture2e(env, "git", "-C", @dir, *args)
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

  def check(**options)
    Exhale::Dry::Check.new(root: @dir, base: "main", cache_dir: File.join(@dir, "tmp", "exhale"), **options).run
  end

  # How many times the block exports a base tree.
  def count_base_exports
    exports = 0
    counting = Module.new do
      define_method(:export_files) do |*args|
        exports += 1
        super(*args)
      end
    end
    real_new = Exhale::Git.method(:new)
    Exhale::Git.define_singleton_method(:new) { |*args| real_new.call(*args).extend(counting) }
    yield
    exports
  ensure
    Exhale::Git.singleton_class.remove_method(:new)
  end

  # Contract: gate/G2
  # Contract: gate/G3
  # Contract: gate/G9
  # Contract: gate/G11
  def test_a_new_copy_is_introduced_and_fails_the_gate
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)

    result = check

    assert_equal 1, result.exit_code
    finding = result.findings.fetch(0)
    assert_equal :introduced, finding.klass
    assert_equal "Receipt#totals", finding.copy.unit.identity
    assert_equal "Invoice#totals", finding.others.fetch(0)[0].unit.identity
    assert_match(/extend or call Invoice#totals/, finding.hint)
  end

  # Contract: gate/G2
  def test_a_contract_clause_keeps_deliberate_duplication
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    write("contract/document_total/duplication.md", <<~MD)
      ## Totals stay separate

      Receipts and invoices total differently under some tax regimes.

      ```parallel
      Invoice
      Receipt
      ```
    MD
    commit("both")

    result = check

    assert_equal 0, result.exit_code, Exhale::Report.render(result, "text")
    assert_empty result.findings
    assert_equal 1, result.kept.size
    assert_equal "Totals stay separate", result.kept.first.clause.heading
  end

  # Contract: gate/G2
  def test_a_stale_clause_fails_the_gate
    write("app/models/invoice.rb", INVOICE)
    write("app/models/shipment.rb", UNRELATED)
    write("contract/document_total/duplication.md", "## Old\n\n```parallel\nInvoice\nShipment\n```\n")
    commit("stale")

    result = check

    assert_equal 1, result.exit_code
    assert_match(/stale clause/, result.clause_errors.first.message)
  end

  # Contract: gate/G4
  # Contract: gate/G7
  # Contract: sweep/W1
  def test_duplication_already_on_main_fails_unless_the_on_ramp_is_on
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", UNRELATED)

    whole = check
    ramp = check(introduced_only: true)

    assert_equal :already_there, whole.findings.first.klass
    assert_equal 1, whole.exit_code
    assert_equal 0, ramp.exit_code
  end

  # Contract: report/R4
  def test_the_same_commit_gets_the_same_report
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")

    first = Exhale::Report.render(check, "json")
    FileUtils.rm_rf(File.join(@dir, "tmp"))
    second = Exhale::Report.render(check, "json")

    assert_equal first, second
  end

  # Value: protects=a pure rename of a duplicated file is not blamed on the PR; fails_when=moving a file with an old duplicate labels it introduced or shifted; why_new=existing tests never move a file; seam=none
  # Contract: gate/G4
  def test_a_pure_move_of_a_duplicated_file_is_already_there
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    FileUtils.mkdir_p(File.join(@dir, "app/billing"))
    git("mv", "app/models/receipt.rb", "app/billing/receipt.rb")

    result = check

    finding = result.findings.fetch(0)
    assert_equal :already_there, finding.klass
    assert_empty finding.touched
    assert_equal "app/billing/receipt.rb", [finding.copy, finding.others.fetch(0)[0]].map(&:path).find { |p| p.include?("billing") }
  end

  # Value: protects=the CONTRACTED report section when a PR removes one side of a base duplicate; fails_when=contracted stays empty or the text report omits the section; why_new=contracted list had no test; seam=none
  # Contract: gate/G5
  def test_removing_one_copy_lists_the_pair_as_contracted
    write("app/models/invoice.rb", INVOICE)
    write("app/models/receipt.rb", RECEIPT)
    commit("both")
    git("checkout", "-q", "-b", "feature")
    git("rm", "-q", "app/models/receipt.rb")

    result = check

    assert_equal 1, result.contracted.size
    assert_equal ["Invoice#totals", "Receipt#totals"], result.contracted.first.then { |c| [c.a, c.b] }.map { |k| k.split("@").first }.sort
    assert_empty result.findings
    assert_match(/^CONTRACTED$/, Exhale::Report.render(result, "text"))
    assert_match(/no longer matches/, Exhale::Report.render(result, "text"))
  end

  # Value: protects=copies in many files collapse into one cluster; fails_when=pairwise findings are emitted or payoff is zero; why_new=clustering was untested; seam=none
  # Contract: gate/G8
  def test_one_method_copied_into_four_files_is_one_finding
    write("app/models/invoice.rb", INVOICE)
    commit("original")
    git("checkout", "-q", "-b", "feature")
    %w[Receipt Quote Order].each { |name| write("app/models/#{name.downcase}.rb", INVOICE.sub("class Invoice", "class #{name}")) }

    result = check

    assert_equal 1, result.findings.size
    finding = result.findings.fetch(0)
    assert_equal 3, finding.others.size
    assert_operator finding.payoff, :>, 0
  end

  # Value: protects=the newest-committed side is reported as the copy; fails_when=ordering falls back to path order or ignores blame; why_new=blame ordering was untested; seam=none
  # Contract: gate/G9
  def test_the_later_committed_side_is_the_copy_when_neither_is_touched
    write("app/models/receipt.rb", RECEIPT)
    commit("receipt first")
    @date = "2026-02-01T00:00:00Z"
    write("app/models/invoice.rb", INVOICE)
    commit("invoice later")
    git("checkout", "-q", "-b", "feature")
    write("app/models/shipment.rb", UNRELATED)

    finding = check.findings.fetch(0)

    assert_equal :already_there, finding.klass
    assert_equal "Invoice#totals", finding.copy.unit.identity
    assert_equal "Receipt#totals", finding.others.fetch(0)[0].unit.identity
  end

  # Value: protects=the base sweep is cached by sha, version and normalizer and survives corruption; fails_when=no cache file is written, a cached run differs, or a corrupt file raises; why_new=cache was only weakly covered; seam=none
  # Contract: gate/G1
  # Contract: sweep/W2
  def test_base_cache_is_written_reused_and_rebuilt_when_corrupt
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)
    cache = File.join(@dir, "tmp", "exhale")

    first = Exhale::Report.render(check, "json")
    files = Dir[File.join(cache, "base-*-#{Exhale::VERSION}-n#{Exhale::Dry::Normalizer::VERSION}-*.json")]
    assert_equal 1, files.size
    assert_match(/base-[0-9a-f]{40}-/, File.basename(files.first))

    assert_equal first, Exhale::Report.render(check, "json")

    File.binwrite(files.first, "not a cache file")
    assert_equal first, Exhale::Report.render(check, "json")
    refute_equal "not a cache file", File.binread(files.first)
  end

  # Value: protects=a warm cache answers for the base, so the base is exported and swept once per key; fails_when=the cache is written but never read, and every run exports and sweeps the base again; why_new=the cache test compared verdicts, which a recompute also passes; seam=a spy on Git#export_files
  # Contract: sweep/W2
  def test_a_warm_cache_skips_exporting_the_base
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)

    assert_equal [1, 0], [count_base_exports { check }, count_base_exports { check }]
  end

  # Value: protects=a base cached under another depth limit is swept again; fails_when=the key leaves the limit out, so a cache from a version that read deeper files answers for this one and a warm run can pass where a cold one fails; why_new=the limit is new; seam=the limit constant swapped for the second run
  # Contract: sweep/W2
  def test_a_cache_from_another_depth_limit_is_not_reused
    write("app/models/invoice.rb", INVOICE)
    commit("invoice")
    git("checkout", "-q", "-b", "feature")
    write("app/models/receipt.rb", RECEIPT)

    assert_equal [1, 1], [count_base_exports { check }, with_depth_limit(Exhale::Units::Depth::LIMIT + 1) { count_base_exports { check } }]
  end

  private

  def with_depth_limit(limit)
    depth = Exhale::Units::Depth
    old = depth::LIMIT
    depth.send(:remove_const, :LIMIT)
    depth.const_set(:LIMIT, limit)
    yield
  ensure
    depth.send(:remove_const, :LIMIT)
    depth.const_set(:LIMIT, old)
  end
end
