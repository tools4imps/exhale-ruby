# frozen_string_literal: true

module Exhale
  class Contract
    # A line scanner for the little Markdown the Contract needs: fenced blocks
    # (CommonMark fence rules), the nearest ATX heading above each, and the
    # prose between that heading and the block. No Markdown gem.
    module Markdown
      Block = Struct.new(:info, :line, :body, :heading, :prose, keyword_init: true) do
        # body is [[text, line_number], ...]
        def reason
          [heading, *prose].compact.join(" ").gsub(/\s+/, " ").strip
        end
      end

      FENCE_OPEN = /\A {0,3}(`{3,}|~{3,})(.*)\z/
      HEADING = /\A {0,3}\#{1,6}(?:[ \t]+(.*))?\z/

      module_function

      def blocks(text)
        state = { blocks: [], heading: nil, prose: [], fence: nil, comment: false }
        text.each_line.with_index(1) { |raw, no| step(state, raw.chomp, no) }
        state[:blocks] << finish(state[:fence]) if state[:fence]
        state[:blocks]
      end

      SETEXT = /\A {0,3}(?:=+|-+)[ \t]*\z/

      def step(state, line, no)
        after_prose = state[:after_prose]
        state[:after_prose] = false
        fence = state[:fence]
        if fence
          continue_fence(state, fence, line, no)
        elsif (line = outside_comments(state, line)).nil?
          nil
        elsif (fence = open_fence(line, no, state))
          state[:fence] = fence
        elsif after_prose && SETEXT.match?(line)
          state[:heading] = state[:prose].pop
          state[:prose] = []
        elsif (m = HEADING.match(line))
          state[:heading] = m[1].to_s.sub(/[ \t]+#+[ \t]*\z/, "").sub(/\A#+\z/, "").strip
          state[:prose] = []
        elsif !line.strip.empty?
          state[:prose] << line.strip
          state[:after_prose] = true
        end
      end

      # Returns the part of the line that is live Markdown, or nil when the
      # whole line sits inside an HTML comment. Fences in comments are dead.
      def outside_comments(state, line)
        if state[:comment]
          return nil unless line.include?("-->")

          state[:comment] = false
          line = line.sub(/\A.*?-->/, "")
        end
        line = line.gsub(/<!--.*?-->/, "")
        return line unless line.include?("<!--")

        state[:comment] = true
        line.sub(/<!--.*\z/, "")
      end

      def continue_fence(state, fence, line, no)
        if closes?(line, fence)
          state[:blocks] << finish(fence)
          state[:fence] = nil
          state[:prose] = [] if %w[parallel settings covers ceiling].include?(fence[:info])
        else
          fence[:body] << [line, no]
        end
      end

      def open_fence(line, no, state)
        m = FENCE_OPEN.match(line)
        return nil unless m
        return nil if m[1].start_with?("`") && m[2].include?("`")

        { char: m[1][0], len: m[1].size, info: m[2].strip.split(/\s+/).first.to_s, line: no, body: [],
          heading: state[:heading], prose: state[:prose].dup }
      end

      def closes?(line, fence)
        m = /\A {0,3}(`{3,}|~{3,})[ \t]*\z/.match(line)
        m && m[1][0] == fence[:char] && m[1].size >= fence[:len]
      end

      def finish(fence)
        Block.new(info: fence[:info], line: fence[:line], body: fence[:body],
                  heading: fence[:heading], prose: fence[:prose])
      end

      # Drops a trailing comment: "#" preceded by whitespace and followed by a
      # space or end of line. A "#" glued to a name is part of a method ref.
      def strip_comment(line)
        stripped = line.strip
        return "" if stripped.match?(/\A#(\s|\z)/)

        stripped.sub(/\s+#(\s.*)?\z/, "")
      end
    end
  end
end
