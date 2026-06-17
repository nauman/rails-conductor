require "faraday"
require "json"

# Thin GitHub REST API client for managing a repo's deploy keys (and, later,
# webhooks). Authenticated with an org token (a fine-grained PAT or a GitHub App
# installation token) — see Organization#github_token.
class GithubClient
  class Error < StandardError; end

  BASE = "https://api.github.com".freeze

  def initialize(token)
    @token = token
  end

  def list_deploy_keys(repo:)
    resp = conn.get("/repos/#{repo}/keys")
    return JSON.parse(resp.body) if resp.success?

    raise Error, error_message(resp)
  end

  # Idempotent: replaces any existing key with the same title.
  def add_deploy_key(repo:, title:, key:, read_only: true)
    existing = list_deploy_keys(repo: repo).find { |k| k["title"] == title }
    delete_deploy_key(repo: repo, id: existing["id"]) if existing

    resp = conn.post("/repos/#{repo}/keys") do |req|
      req.body = JSON.generate(title: title, key: key, read_only: read_only)
    end
    return JSON.parse(resp.body) if resp.status == 201

    raise Error, error_message(resp)
  end

  def delete_deploy_key(repo:, id:)
    resp = conn.delete("/repos/#{repo}/keys/#{id}")
    return true if resp.status == 204

    raise Error, error_message(resp)
  end

  private

  def conn
    @conn ||= Faraday.new(url: BASE) do |f|
      f.headers["Authorization"] = "Bearer #{@token}"
      f.headers["Accept"] = "application/vnd.github+json"
      f.headers["X-GitHub-Api-Version"] = "2022-11-28"
      f.headers["User-Agent"] = "Conductor"
      f.headers["Content-Type"] = "application/json"
      f.options.timeout = 15
    end
  end

  def error_message(resp)
    body = JSON.parse(resp.body) rescue {}
    "GitHub API #{resp.status}: #{body["message"] || resp.body.to_s[0, 120]}"
  end
end
