# frozen_string_literal: true

require_relative "lib/trueup/version"

Gem::Specification.new do |s|
  s.name        = "trueup"
  s.version     = TrueUp::VERSION
  s.summary     = "Official TrueUp API client for Ruby: reconcile ledgers, statements and bank feeds"
  s.description = "Send TrueUp two ledgers and it pairs every row, then tells you what's only on one side, " \
                  "what was counted twice and where the numbers disagree."
  s.authors     = ["Merchant Protocol"]
  s.license     = "MIT"
  s.homepage    = "https://github.com/merchantprotocol/trueup-ruby"
  s.metadata    = {
    "homepage_uri" => "https://trueup-cloud.merchantprotocol.workers.dev/docs#sdks",
    "source_code_uri" => "https://github.com/merchantprotocol/trueup-ruby",
    "bug_tracker_uri" => "https://github.com/merchantprotocol/trueup-ruby/issues",
    "rubygems_mfa_required" => "true",
  }
  s.required_ruby_version = ">= 3.0"
  s.files = Dir["lib/**/*.rb"] + ["README.md", "LICENSE"]
  s.require_paths = ["lib"]
end
