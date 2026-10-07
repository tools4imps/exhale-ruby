# frozen_string_literal: true

require "digest"
require "find"
require "pathname"
require_relative "unit"
require_relative "errors"
require_relative "contract/markdown"
require_relative "contract/reference"
require_relative "contract/resolver"

module Exhale
  # The Contract: Markdown under <root>/contract/<primitive>/ that declares which
  # code belongs to a primitive, which units are deliberately parallel, and
  # which stay complex up to a ceiling. Each check reads only its own files:
  # duplication.md for dry, complexity.md for complexity.
  class Contract
    Primitive = Struct.new(:name, :path, :covers)
    # max is a ceiling's limit, nil for a parallel clause.
    Clause = Struct.new(:primitive, :kind, :path, :line, :heading, :reason, :references, :key, :max)

    CONTENT = %w[covers parallel settings ceiling].freeze
    # The blocks each check's own file holds, and the settings it takes.
    BLOCKS = { dry: %w[parallel settings], complexity: %w[ceiling settings] }.freeze
    SETTING_KEYS = {
      dry: { "threshold" => :threshold, "min-lines" => :min_lines, "min-nodes" => :min_nodes },
      complexity: { "floor" => :floor }
    }.freeze
    HOME = { "parallel" => "duplication.md", "ceiling" => "complexity.md", "covers" => "README.md" }.freeze
    # A floor of 0 is allowed: every rise then fails.
    MINIMUMS = { min_lines: 1, min_nodes: 1, floor: 0 }.freeze
    MAX = /\Amax:\s*(.*)\z/

    attr_reader :primitives, :clauses, :settings, :errors

    def self.load(root, dir: "contract", check: :dry)
      new(root, dir, check).tap(&:parse)
    end

    def initialize(root, dir, check = :dry)
      raise ArgumentError, "unknown check #{check.inspect}" unless BLOCKS.key?(check)

      @root = Pathname.new(root.to_s)
      @dir = dir
      @check = check
      @primitives = []
      @clauses = []
      @settings = {}
      @errors = []
    end

    def parse
      base = @root.join(@dir)
      return self unless base.directory? || base.symlink?

      flag_symlinks(base)
      return self if base.symlink?

      check_root_files(base)
      base.children.select { |d| real_dir?(d) }.reject { |d| d.basename.to_s.start_with?(".") }
          .sort_by { |d| d.basename.to_s }.each { |d| parse_primitive(d) }
      @clauses.sort_by! { |c| [c.path, c.line] }
      self
    end

    private

    # Symlinks could point outside the repo and change the verdict without
    # changing the commit, so every one is an error and none is followed.
    def flag_symlinks(base)
      Find.find(base.to_s) do |path|
        next unless File.symlink?(path)

        @errors << ContractError.new(rel(path), 1, "symlinks are not allowed in the Contract")
        Find.prune
      end
    end

    def real_dir?(path)
      path.directory? && !path.symlink?
    end

    def real_file?(path)
      path.file? && !path.symlink?
    end

    def parse_primitive(dir)
      name = dir.basename.to_s
      covers = []
      readme = dir.join("README.md")
      each_block(readme) { |block, path| readme_block(covers, block, path) } if real_file?(readme)
      @primitives << Primitive.new(name, rel(dir), covers)
      check_files(dir).each do |file|
        each_block(file) { |block, path| check_block(name, block, path) }
      end
      stray_files(dir).each do |file|
        each_block(file) do |block, path|
          next unless CONTENT.include?(block.info)

          misplaced(block, path, "found in a stray file; use README.md, duplication.md or complexity.md")
        end
      end
    end

    def check_files(dir)
      return duplication_files(dir) if @check == :dry

      file = dir.join("complexity.md")
      real_file?(file) ? [file] : []
    end

    def stray_files(dir)
      known = %w[README.md duplication.md complexity.md].map { |name| dir.join(name).to_s }
      markdown_files(dir).reject { |f| known.include?(f.to_s) || f.to_s.start_with?(dir.join("duplication/").to_s) }
    end

    def markdown_files(dir)
      Dir.glob("**/*.md", base: dir.to_s).sort.map { |f| dir.join(f) }.reject { |f| f.symlink? || !f.file? }
    end

    def readme_block(covers, block, path)
      case block.info
      when "covers" then covers.concat(references(block, path))
      when "parallel", "ceiling" then misplaced(block, path, "belongs in #{HOME[block.info]}")
      when "settings" then misplaced(block, path, "belongs in duplication.md or complexity.md")
      end
    end

    def misplaced(block, path, message)
      @errors << ContractError.new(path, block.line, "#{block.info} block #{message}")
    end

    def check_root_files(base)
      base.children.select { |f| real_file?(f) }.select { |f| f.extname == ".md" }.sort_by(&:to_s).each do |file|
        each_block(file) do |block, path|
          misplaced(block, path, "found at the contract root; Contract content must live in a primitive directory") if CONTENT.include?(block.info)
        end
      end
    end

    def duplication_files(dir)
      files = []
      single = dir.join("duplication.md")
      files << single if real_file?(single)
      nested = dir.join("duplication")
      files.concat(markdown_files(nested)) if real_dir?(nested)
      files.sort_by(&:to_s)
    end

    def each_block(file)
      path = rel(file)
      text = File.read(file, encoding: "UTF-8")
      return @errors << ContractError.new(path, 1, "file is not valid UTF-8") unless text.valid_encoding?

      Markdown.blocks(text).each { |block| yield block, path }
    end

    # A block type that belongs to the other check, or to README.md, is an
    # error where it sits.
    def check_block(primitive, block, path)
      return unless CONTENT.include?(block.info)
      return misplaced(block, path, "belongs in #{HOME[block.info]}") unless BLOCKS[@check].include?(block.info)

      case block.info
      when "parallel" then add_clause(primitive, block, path)
      when "ceiling" then add_ceiling(primitive, block, path)
      else add_settings(primitive, block, path)
      end
    end

    def references(block, path)
      block.body.filter_map do |text, no|
        ref = Markdown.strip_comment(text)
        Reference.new(ref, path, no) unless ref.empty?
      end
    end

    def add_clause(primitive, block, path)
      refs = references(block, path)
      return @errors << ContractError.new(path, block.line, "empty parallel block") if refs.empty?

      key = Digest::SHA256.hexdigest("#{primitive}|parallel|#{refs.map(&:text).sort.join("\n")}")
      @clauses << Clause.new(primitive, :parallel, path, block.line, block.heading, block.reason, refs, key)
    end

    # A ceiling names units and gives one `max: N` they may reach.
    def add_ceiling(primitive, block, path)
      lines = block.body.map { |text, no| [Markdown.strip_comment(text), no] }.reject { |line, _| line.empty? }
      maxes, names = lines.partition { |line, _| MAX.match?(line) }
      return @errors << ContractError.new(path, block.line, "ceiling block names no unit") if names.empty?
      return unless (max = ceiling_max(maxes, block, path))

      refs = names.map { |line, no| Reference.new(line, path, no) }
      key = Digest::SHA256.hexdigest("#{primitive}|ceiling|#{max}|#{refs.map(&:text).sort.join("\n")}")
      @clauses << Clause.new(primitive, :ceiling, path, block.line, block.heading, block.reason, refs, key, max)
    end

    # The one max a ceiling gives, or nil once the reason it has none is
    # recorded.
    def ceiling_max(maxes, block, path)
      return ceiling_error(path, block.line, "ceiling block needs max: N") if maxes.empty?
      return ceiling_error(path, maxes[1].last, "repeated max in a ceiling block") if maxes.size > 1

      text, no = maxes.first
      value = MAX.match(text)[1]
      max = Integer(value, 10, exception: false)
      max && max >= 0 ? max : ceiling_error(path, no, "bad value for max: #{value.inspect}")
    end

    def ceiling_error(path, line, message)
      @errors << ContractError.new(path, line, message)
      nil
    end

    def add_settings(primitive, block, path)
      if @settings.key?(primitive)
        return @errors << ContractError.new(path, block.line, "second settings block for #{primitive}")
      end

      @settings[primitive] = block.body.each_with_object({}) do |(text, no), acc|
        line = Markdown.strip_comment(text)
        next if line.empty?

        parse_setting(line, path, no, acc)
      end
    end

    def parse_setting(line, path, no, acc)
      key, value = line.split(":", 2).map(&:strip)
      sym = SETTING_KEYS[@check][key]
      return @errors << ContractError.new(path, no, "unknown setting: #{key}") unless sym

      parsed = setting_value(sym, value)
      return @errors << ContractError.new(path, no, "bad value for #{key}: #{value.inspect}") if parsed.nil?

      return @errors << ContractError.new(path, no, "repeated setting: #{key}") if acc.key?(sym)

      acc[sym] = parsed
    end

    def setting_value(sym, value)
      if sym == :threshold
        f = Float(value, exception: false)
        f if f && f > 0 && f <= 1
      else
        i = Integer(value.to_s, 10, exception: false)
        i if i && i >= MINIMUMS.fetch(sym)
      end
    end

    def rel(path)
      Pathname.new(path.to_s).relative_path_from(@root).to_s
    end
  end
end
