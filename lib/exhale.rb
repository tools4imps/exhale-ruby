# frozen_string_literal: true

require_relative "exhale/version"
require_relative "exhale/errors"
require_relative "exhale/shape"
require_relative "exhale/unit"
require_relative "exhale/git"
require_relative "exhale/source_files"
require_relative "exhale/units/ruby"
require_relative "exhale/units/erb"
require_relative "exhale/units"
require_relative "exhale/contract"
require_relative "exhale/dry/normalizer/ruby"
require_relative "exhale/dry/normalizer/erb"
require_relative "exhale/dry/normalizer"
require_relative "exhale/dry/fingerprints"
require_relative "exhale/dry/index"
require_relative "exhale/dry/matcher"
require_relative "exhale/dry/gate"
require_relative "exhale/dry/check"
require_relative "exhale/complexity/cognitive"
require_relative "exhale/complexity/ratchet"
require_relative "exhale/complexity/check"
require_relative "exhale/report"
require_relative "exhale/cli"

# exhale gates the exhale of every pull request. See README.md.
module Exhale
end
