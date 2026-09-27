# TrueUp for Ruby

The official client for the [TrueUp API](https://trueup-cloud.merchantprotocol.workers.dev/docs). Send TrueUp two ledgers (a supplier statement and your receiving log, your books and the bank feed, invoices and payments) and it pairs every row, then tells you what's only on one side, what was counted twice and where the numbers disagree.

Ruby 3.0+. No dependencies beyond the standard library.

## Install

```bash
gem install trueup
```

## Quickstart

Create an API key in the TrueUp dashboard (**API keys**), then set `TRUEUP_API_KEY`:

```ruby
require "trueup"

trueup = TrueUp::Client.new # reads TRUEUP_API_KEY

result = trueup.reconcile("statement.csv", "receiving.csv") # left: the side that bills or claims

puts result["headline"]
# 7 of 8 rows of statement.csv paired with receiving.csv; 1 only in statement.csv, ...
result["findings"].each do |f|
  puts "#{f['kind']} #{f['subject']} #{f['detail']} #{f['amount']}"
end
# qty_mismatch statement.csv:row 5 Qty 24 vs qty_received 20; ... 99.6
# phantom statement.csv:row 6 no match on the other side 43.2
```

## Reconcile

A table is a path, file contents, or rows:

```ruby
trueup.reconcile("books.csv", "bank.csv")
trueup.reconcile(TrueUp::Table.content("books.csv", csv), TrueUp::Table.content("bank.csv", bytes))
trueup.reconcile(
  TrueUp::Table.rows("invoices", [{ "Invoice #" => "INV-10101", "Date" => "2026-06-09", "Total" => "$2,999.31" }]),
  TrueUp::Table.rows("payments", [{ "Received" => "2026-07-01", "From" => "ACME CONSTR", "Amount" => "2999.31" }])
)
```

CSV, TSV, JSON and JSON Lines are read, and date and number formats are detected. Nothing about the columns is configured.

Not sure which file is which? `trueup.reconcile_files(["a.csv", "b.csv"])` picks the pair and the sides.

**Reuse what was learned** by passing an earlier result's weights, and **answer the questions** TrueUp wasn't sure about:

```ruby
march = trueup.reconcile("march-statement.csv", "march-receiving.csv")
april = trueup.reconcile("april-statement.csv", "april-receiving.csv", weights: march["details"]["weights"])

trueup.reconcile("statement.csv", "receiving.csv", answers: {
  "same" => [["statement.csv:row 12", "receiving.csv:row 11"]],
  "different" => [["statement.csv:row 3", "receiving.csv:row 9"]]
})
```

Each call to `reconcile` or `reconcile_files` counts as one analysis on your plan.

## Findings

| `kind` | Meaning |
|---|---|
| `phantom` | Only on the left: billed or recorded, never matched |
| `unbilled` | Only on the right: received or paid, never billed |
| `duplicate`, `received_duplicate` | A copy of a row that's already paired |
| `qty_mismatch`, `price_change`, `amount_mismatch` | Paired rows whose numbers disagree |
| `unsure_pair` | A likely pair a person should confirm |

## Account and usage

```ruby
trueup.account # {"team" => ..., "plan" => ..., "key" => ...}
trueup.usage   # {"period" => ..., "metrics" => [...]}
trueup.plans
```

## Errors

Every error is a `TrueUp::Error` with `status`, `code` (the API's error code) and `message`:

| Class | When |
|---|---|
| `TrueUp::AuthenticationError` | 401: missing, unknown or revoked key |
| `TrueUp::InvalidRequestError` | 400, 413, 415, 422: the request or the files need fixing (`unsupported_file`, `not_reconcilable`, ...) |
| `TrueUp::RateLimitError` | 429 `rate_limited`: retried automatically; `retry_after` seconds |
| `TrueUp::QuotaExceededError` | 429 `quota_exceeded`: the plan's monthly allowance is used up |
| `TrueUp::ServerError` | 5xx: retried automatically |
| `TrueUp::ConnectionError` | the API couldn't be reached |

## Configuration

```ruby
TrueUp::Client.new(
  api_key: "tu_live_...",    # default: TRUEUP_API_KEY
  base_url: "https://...",   # default: TRUEUP_BASE_URL, then the hosted API
  timeout: 300,              # seconds per request
  max_retries: 2             # rate limits, 5xx and dropped connections
)
```

## Development

The tests run in Docker against the live API:

```bash
export TRUEUP_API_KEY=tu_live_...   # a key for a test team (each run uses 2 analyses)
just test                            # or: docker compose run --rm test
```

## License

MIT
