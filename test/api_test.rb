# frozen_string_literal: true

# Integration tests against the live TrueUp API. Need TRUEUP_API_KEY (and optionally TRUEUP_BASE_URL).
# Each full run uses 2 analyses. Run in Docker: `just test` (or `docker compose run --rm test`).

require "csv"
require "minitest/autorun"
require "trueup"

class ApiTest < Minitest::Test
  FIXTURES = File.join(__dir__, "fixtures")

  def fixture(name)
    File.join(FIXTURES, name)
  end

  def rows(name)
    CSV.read(fixture(name), headers: true).map(&:to_h)
  end

  def live!
    skip "needs TRUEUP_API_KEY" if ENV["TRUEUP_API_KEY"].to_s.empty?
  end

  def test_missing_api_key_fails_before_any_request
    saved = ENV.delete("TRUEUP_API_KEY")
    error = assert_raises(TrueUp::AuthenticationError) { TrueUp::Client.new }
    assert_equal "missing_api_key", error.code
  ensure
    ENV["TRUEUP_API_KEY"] = saved if saved
  end

  def test_account_usage_plans
    live!
    tu = TrueUp::Client.new
    assert tu.account["key"]["prefix"].start_with?("tu_live_")
    assert(tu.usage["metrics"].any? { |m| m["metric"] == "analyses" })
    assert(tu.plans.any? { |p| p["slug"] == "free" })
  end

  def test_reconcile_files_then_rows_with_saved_weights
    live!
    tu = TrueUp::Client.new
    result = tu.reconcile(fixture("statement.csv"), fixture("receiving.csv"))
    assert_equal "reconcile", result["analysis"]
    assert_equal 7, result["stats"]["paired"]
    assert_equal [["qty_mismatch", "statement.csv:row 5"], ["phantom", "statement.csv:row 6"]],
                 result["findings"].map { |f| [f["kind"], f["subject"]] }
    assert_in_delta 43.2, result["findings"][1]["amount"], 1e-9
    weights = result["details"]["weights"]
    assert_equal "trueup.match-weights", weights["format"]

    again = tu.reconcile(TrueUp::Table.rows("statement.csv", rows("statement.csv")),
                         TrueUp::Table.rows("receiving.csv", rows("receiving.csv")), weights: weights)
    assert_equal 7, again["stats"]["paired"]
    assert_equal false, again["details"]["model"]["learned"]
  end

  def test_errors_are_typed
    live!
    error = assert_raises(TrueUp::AuthenticationError) { TrueUp::Client.new(api_key: "tu_live_#{'x' * 40}").account }
    assert_equal [401, "invalid_api_key"], [error.status, error.code]
    error = assert_raises(TrueUp::InvalidRequestError) do
      TrueUp::Client.new.reconcile(fixture("statement.csv"), TrueUp::Table.content("scan.pdf", "%PDF-1.4"))
    end
    assert_equal [422, "unsupported_file"], [error.status, error.code]
  end
end
