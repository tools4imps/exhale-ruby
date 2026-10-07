# frozen_string_literal: true

require_relative "errors"
require_relative "source_files"
require_relative "units/ruby"
require_relative "units/erb"

module Exhale
  # The units of a tree, read from the files SourceFiles lists.
  module Units
    module_function

    # [units, parse errors]. A file that can't be read, or isn't UTF-8, is a
    # parse error like any other: no gate passes code it didn't read.
    def read(root, files: nil, include_tests: false)
      errors = []
      units = SourceFiles.list(root, files: files, include_tests: include_tests).flat_map do |path, language|
        source = source(root, path)
        language == :ruby ? Ruby.extract(source, path) : Erb.extract(source, path)
      rescue ParseError => e
        errors << e
        []
      end
      [units, errors]
    end

    def source(root, path)
      source = File.read(File.join(root, path), encoding: "UTF-8")
      return source if source.valid_encoding?

      line = source.each_line.find_index { |text| !text.valid_encoding? }.to_i + 1
      raise ParseError.new(path, line, "isn't valid UTF-8")
    rescue SystemCallError, IOError => e
      raise ParseError.new(path, 1, "can't be read: #{e.message}")
    end
  end
end
