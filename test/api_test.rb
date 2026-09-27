# frozen_string_literal: true

# Integration tests against the live TrueUp API. Need TRUEUP_API_KEY (and optionally TRUEUP_BASE_URL).
# Each full run uses 8 analyses. Run in Docker: `just test` (or `docker compose run --rm test`).

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

  def test_stored_files_runs_and_models
    live!
    tu = TrueUp::Client.new
    statement, receiving = tu.upload_files(fixture("statement.csv"), fixture("receiving.csv"))
    begin
      assert_equal 8, statement["rows"]
      assert_equal "receiving.csv", tu.get_file(receiving["id"])["name"]
      assert_includes tu.list_files.map { |f| f["id"] }, statement["id"]
      assert_equal File.binread(fixture("statement.csv")), tu.file_content(statement["id"])

      result = tu.reconcile_stored(statement["id"], receiving["id"])
      assert_equal 7, result["stats"]["paired"]
      got = tu.get_run(result["run_id"])
      assert_equal "done", got["run"]["status"]
      assert_equal 7, got["result"]["stats"]["paired"]
      page = tu.list_runs(limit: 1)
      assert_equal 1, page["runs"].size
      assert page["has_more"]
      refute_equal page["runs"][0]["id"], tu.list_runs(limit: 1, before: page["runs"][0]["id"])["runs"][0]["id"]

      model_id = tu.create_model(result["run_id"], "sdk test")
      begin
        assert_equal "trueup.match-weights", tu.get_model(model_id)["weights"]["format"]
        again = tu.reconcile_stored(file_ids: [statement["id"], receiving["id"]], model: model_id)
        assert_equal false, again["details"]["model"]["learned"]
      ensure
        tu.delete_model(model_id)
      end
      assert_raises(TrueUp::NotFoundError) { tu.get_model(model_id) }
    ensure
      tu.delete_file(statement["id"])
      tu.delete_file(receiving["id"])
    end
    assert_raises(TrueUp::NotFoundError) { tu.get_file(statement["id"]) }
  end

  MATCHED = [%w[1 1], %w[2 2], %w[3 3], %w[4 5]].freeze

  def test_match_two_lists_then_reuse_the_learning
    live!
    tu = TrueUp::Client.new
    result = tu.match(fixture("invoice.csv"), fixture("catalog.csv"))
    assert_equal "match", result["analysis"]
    assert_equal MATCHED, result["details"]["pairs"].map { |p| p[0, 2] }
    assert_equal ["5"], result["findings"].select { |f| f["kind"] == "only_left" }.map { |f| f["subject"] }
    again = tu.match(TrueUp::Table.rows("invoice.csv", rows("invoice.csv")), TrueUp::Table.rows("catalog.csv", rows("catalog.csv")),
                     weights: result["details"]["weights"])
    assert_equal MATCHED, again["details"]["pairs"].map { |p| p[0, 2] }
    assert_equal false, again["details"]["model"]["learned"]
  end

  def test_audit_six_invoices_then_one_against_the_saved_laws
    live!
    tu = TrueUp::Client.new
    result = tu.audit((1..6).map { |i| fixture("invoices/inv-104#{i}.txt") })
    assert_equal "audit", result["analysis"]
    assert_equal [["inv-1045.txt", "yes", 200]], result["findings"].map { |f| [f["subject"], f["status"], f["amount"]] }
    assert_includes result["details"]["laws"].map { |l| l["law"] }, "subtotal + tax amount = total"
    one = tu.audit([fixture("invoices/inv-1045.txt")], weights: result["details"]["weights"])
    assert_equal false, one["details"]["model"]["learned"]
    assert_equal ["inv-1045.txt"], one["findings"].map { |f| f["subject"] }
  end
end
