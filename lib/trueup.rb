# frozen_string_literal: true

require "json"
require "net/http"
require "securerandom"
require "uri"
require_relative "trueup/version"

# TrueUp API client.
#
#   trueup = TrueUp::Client.new                    # reads TRUEUP_API_KEY
#   result = trueup.reconcile("statement.csv", "receiving.csv")
#   result["findings"].each { |f| puts "#{f['kind']} #{f['subject']} #{f['detail']}" }
module TrueUp
  DEFAULT_BASE_URL = "https://trueup-cloud.merchantprotocol.workers.dev"

  # Any error the API returned, or a failure to reach it. +code+ is the API's error code; branch on it.
  class Error < StandardError
    attr_reader :status, :code, :body

    def initialize(message, status: 0, code: "connection_error", body: nil)
      super(message)
      @status = status
      @code = code
      @body = body
    end
  end

  # 401: missing, unknown or revoked API key.
  class AuthenticationError < Error; end
  # 400, 413, 415, 422: the request or the files need fixing.
  class InvalidRequestError < Error; end
  # 404, 405.
  class NotFoundError < Error; end
  # 429 rate_limited: slow down. +retry_after+ is in seconds.
  class RateLimitError < Error
    attr_accessor :retry_after
  end
  # 429 quota_exceeded: the team used its plan's allowance this month. Retrying won't help.
  class QuotaExceededError < Error; end
  # 5xx.
  class ServerError < Error; end
  # The API couldn't be reached, or took too long.
  class ConnectionError < Error; end

  # A table to reconcile: a file, file contents, or rows. +name+ is how findings refer to its rows
  # ("statement.csv:row 5").
  #
  #   TrueUp::Table.file("statement.csv")
  #   TrueUp::Table.content("statement.csv", csv_text)
  #   TrueUp::Table.rows("statement.csv", [{ "Date" => "2026-08-03", "Amount" => "$99.60" }])
  class Table
    attr_reader :name, :rows

    def self.file(path, name: nil)
      new(name || File.basename(path), content: File.binread(path))
    end

    def self.content(name, content)
      new(name, content: content.to_s.b)
    end

    def self.rows(name, rows)
      new(name, rows: rows.to_a)
    end

    def initialize(name, content: nil, rows: nil)
      @name = name
      @content = content
      @rows = rows
    end

    def rows?
      !@rows.nil?
    end

    # [file name, bytes] for a multipart upload.
    def to_file
      return [@name, @content || ""] unless rows?

      stem = @name.include?(".") ? @name[0...@name.rindex(".")] : @name
      ["#{stem}.json", JSON.generate(@rows)]
    end
  end

  # A client for the TrueUp API.
  class Client
    attr_reader :base_url

    # api_key::     defaults to the TRUEUP_API_KEY environment variable
    # base_url::    defaults to TRUEUP_BASE_URL, then the hosted API
    # timeout::     seconds per request (big ledgers take a while)
    # max_retries:: retries for rate limits, server errors and dropped connections
    def initialize(api_key: nil, base_url: nil, timeout: 300, max_retries: 2)
      key = present(api_key) || present(ENV["TRUEUP_API_KEY"])
      unless key
        raise AuthenticationError.new(
          "No API key: pass api_key: or set TRUEUP_API_KEY. Create one in the TrueUp dashboard under API keys.",
          code: "missing_api_key"
        )
      end
      @api_key = key
      @base_url = (present(base_url) || present(ENV["TRUEUP_BASE_URL"]) || DEFAULT_BASE_URL).chomp("/")
      @timeout = timeout
      @max_retries = max_retries
    end

    # The team, plan and key behind this client's API key.
    def account
      request(:get, "/v1/account")
    end

    # This month's usage for the key's team.
    def usage
      request(:get, "/v1/usage")
    end

    # The plans a team can be on.
    def plans
      request(:get, "/v1/plans")["plans"]
    end

    # Reconcile two tables. +left+ is the side that bills or claims (a statement, your books), +right+ the other
    # side (receiving log, bank feed): a path or a Table. Counts as one analysis.
    #
    # weights:: details["weights"] from an earlier result, to apply instead of learning again
    # answers:: { "same" => [[left row, right row]], "different" => [...] }: decisions a person made
    def reconcile(left, right, weights: nil, answers: nil)
      l = table(left)
      r = table(right)
      if l.rows? && r.rows?
        body = { "left" => { "name" => l.name, "rows" => l.rows }, "right" => { "name" => r.name, "rows" => r.rows } }
        body["weights"] = weights unless weights.nil?
        body["answers"] = answers unless answers.nil?
        return request(:post, "/v1/reconcile", json: body)
      end
      request(:post, "/v1/reconcile", parts: [["left", *l.to_file], ["right", *r.to_file]], fields: options(weights, answers))
    end

    # Send two or more files; TrueUp picks the pair to reconcile and which side is which. One analysis.
    def reconcile_files(files, weights: nil, answers: nil)
      parts = files.map { |f| ["files", *table(f).to_file] }
      request(:post, "/v1/reconcile", parts: parts, fields: options(weights, answers))
    end

    # Upload one or more files (paths or Tables) to the team. Each comes back with its "id", "rows", "columns" and
    # "roles" (what TrueUp read each column as).
    def upload_files(*files)
      raise InvalidRequestError.new("Pass at least one file to upload.", code: "invalid_request") if files.empty?

      request(:post, "/v1/files", parts: files.map { |f| ["file", *table(f).to_file] })["files"]
    end

    # The team's stored files.
    def list_files
      request(:get, "/v1/files")["files"]
    end

    def get_file(id)
      request(:get, "/v1/files/#{esc(id)}")["file"]
    end

    # The file's bytes, exactly as uploaded (a binary String).
    def file_content(id)
      request(:get, "/v1/files/#{esc(id)}/content", binary: true)
    end

    def delete_file(id)
      request(:delete, "/v1/files/#{esc(id)}")
      nil
    end

    # Reconcile files already stored in the team, by id: two ids (left bills or claims), or +file_ids:+ for TrueUp to
    # pick the pair. +model:+ applies a saved model instead of learning. The run is kept: its id is "run_id" in the
    # result. One analysis.
    def reconcile_stored(left_file_id = nil, right_file_id = nil, file_ids: nil, model: nil, answers: nil)
      body = if file_ids
               { "file_ids" => file_ids.to_a }
             elsif left_file_id && right_file_id
               { "left_file_id" => left_file_id, "right_file_id" => right_file_id }
             else
               raise InvalidRequestError.new("Pass left_file_id and right_file_id, or file_ids:.", code: "invalid_request")
             end
      body["model"] = model unless model.nil?
      body["answers"] = answers unless answers.nil?
      request(:post, "/v1/reconcile", json: body)
    end

    # One page of runs on stored files, newest first: { "runs" => [...], "has_more" => bool }.
    # +limit+ is 1-100; +before+ a run id.
    def list_runs(limit: nil, before: nil)
      query = URI.encode_www_form({ "limit" => limit, "before" => before }.compact)
      request(:get, "/v1/runs#{query.empty? ? "" : "?#{query}"}")
    end

    # Every run, fetching page after page (an Enumerator without a block).
    def each_run(&block)
      return enum_for(:each_run) unless block

      before = nil
      loop do
        page = list_runs(limit: 100, before: before)
        page["runs"].each(&block)
        break if !page["has_more"] || page["runs"].empty?

        before = page["runs"].last["id"]
      end
    end

    # { "run" => {...}, "result" => {...} }: the result has the same shape #reconcile returns.
    def get_run(id)
      request(:get, "/v1/runs/#{esc(id)}")
    end

    # Save what a run learned as a model. Returns the model id.
    def create_model(run_id, name = nil)
      request(:post, "/v1/models", json: { "run_id" => run_id, "name" => name }.compact)["id"]
    end

    def list_models
      request(:get, "/v1/models")["models"]
    end

    # One saved model, including its "weights".
    def get_model(id)
      request(:get, "/v1/models/#{esc(id)}")["model"]
    end

    def delete_model(id)
      request(:delete, "/v1/models/#{esc(id)}")
      nil
    end

    private

    def esc(id)
      URI.encode_www_form_component(id.to_s).gsub("+", "%20")
    end

    def present(value)
      value.nil? || value.to_s.empty? ? nil : value.to_s
    end

    def table(value)
      value.is_a?(Table) ? value : Table.file(value.to_s)
    end

    def options(weights, answers)
      out = {}
      out["weights"] = JSON.generate(weights) unless weights.nil?
      out["answers"] = JSON.generate(answers) unless answers.nil?
      out
    end

    def request(method, path, json: nil, parts: nil, fields: {}, binary: false)
      uri = URI(@base_url + path)
      attempt = 0
      loop do
        req = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method).new(uri)
        req["Authorization"] = "Bearer #{@api_key}"
        req["Accept"] = "application/json"
        req["User-Agent"] = "trueup-ruby/#{VERSION}"
        if json
          req["Content-Type"] = "application/json"
          req.body = JSON.generate(json)
        elsif parts
          boundary = "----trueup#{SecureRandom.hex(12)}"
          req["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          req.body = multipart(boundary, parts, fields)
        end
        begin
          res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                open_timeout: 30, read_timeout: @timeout, write_timeout: @timeout) { |h| h.request(req) }
        rescue StandardError => e
          if attempt < @max_retries
            sleep(backoff(attempt))
            attempt += 1
            next
          end
          raise ConnectionError.new("Couldn't reach TrueUp at #{@base_url}: #{e.message}")
        end
        return res.body.to_s.b if binary && res.code.to_i.between?(200, 299)

        data = begin
          res.body.to_s.empty? ? nil : JSON.parse(res.body)
        rescue JSON::ParserError
          res.body
        end
        status = res.code.to_i
        return data if status.between?(200, 299)

        err = data.is_a?(Hash) && data["error"].is_a?(Hash) ? data["error"] : {}
        error = error_for(status, err["code"] || "http_#{status}", err["message"] || "HTTP #{status}", data, res["retry-after"])
        if (error.is_a?(RateLimitError) || error.is_a?(ServerError)) && attempt < @max_retries
          sleep(error.is_a?(RateLimitError) && error.retry_after ? error.retry_after : backoff(attempt))
          attempt += 1
          next
        end
        raise error
      end
    end

    def error_for(status, code, message, body, retry_after)
      args = { status: status, code: code, body: body }
      return AuthenticationError.new(message, **args) if status == 401
      return QuotaExceededError.new(message, **args) if status == 429 && code == "quota_exceeded"

      if status == 429
        e = RateLimitError.new(message, **args)
        e.retry_after = retry_after&.to_f
        return e
      end
      return NotFoundError.new(message, **args) if [404, 405].include?(status)
      return ServerError.new(message, **args) if status >= 500

      InvalidRequestError.new(message, **args)
    end

    def multipart(boundary, parts, fields)
      body = +"".b
      fields.each do |name, value|
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{name}\"\r\n\r\n".b << value.to_s.b << "\r\n".b
      end
      parts.each do |field, filename, bytes|
        safe = filename.to_s.tr("\"\r\n", "___")
        body << "--#{boundary}\r\nContent-Disposition: form-data; name=\"#{field}\"; filename=\"#{safe}\"\r\n".b
        body << "Content-Type: application/octet-stream\r\n\r\n".b << bytes.to_s.b << "\r\n".b
      end
      body << "--#{boundary}--\r\n".b
    end

    def backoff(attempt)
      [30.0, 2.0**attempt].min * (0.5 + (rand / 2))
    end
  end
end
