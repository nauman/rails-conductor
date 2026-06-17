require "openssl"
require "base64"
require "faraday"
require "json"

# GitHub App authentication: mint app JWTs and short-lived installation tokens so
# Conductor can clone/pull any repo in an org where the App is installed — no
# per-repo deploy keys, works across orgs. One App (app_id + private key) stored
# as a Conductor-global Credential (provider "github_app"); installations are
# discovered per repo.
class GithubApp
  class Error < StandardError; end
  class NotConfigured < StandardError; end

  BASE = "https://api.github.com".freeze

  def self.from_config
    cred = Credential.for_provider("github_app").active.first
    return nil unless cred&.api_key.present? && cred.api_secret.present?

    new(app_id: cred.api_key, private_key: cred.api_secret)
  end

  def initialize(app_id:, private_key:)
    @app_id = app_id
    @private_key = private_key
  end

  # App-level JWT (RS256), ~10 min — clock skew guarded. Signed directly with
  # OpenSSL (no jwt gem dependency).
  def app_jwt(now: Time.now.to_i)
    rsa = OpenSSL::PKey::RSA.new(@private_key)
    header  = b64(JSON.generate(alg: "RS256", typ: "JWT"))
    payload = b64(JSON.generate(iat: now - 60, exp: now + 540, iss: @app_id.to_s))
    signing_input = "#{header}.#{payload}"
    signature = b64(rsa.sign(OpenSSL::Digest.new("SHA256"), signing_input))
    "#{signing_input}.#{signature}"
  rescue OpenSSL::PKey::RSAError => e
    raise Error, "Invalid GitHub App private key: #{e.message}"
  end

  # Installation id for a repo's org (App must be installed there).
  def installation_id_for(repo)
    resp = app_conn.get("/repos/#{repo}/installation")
    raise Error, error_message(resp) unless resp.success?

    JSON.parse(resp.body)["id"]
  end

  # A short-lived (1h) installation token that can clone/pull.
  def installation_token(installation_id)
    resp = app_conn.post("/app/installations/#{installation_id}/access_tokens")
    raise Error, error_message(resp) unless resp.status == 201

    JSON.parse(resp.body)["token"]
  end

  # Convenience: a token scoped to clone `owner/repo`.
  def clone_token_for(repo)
    installation_token(installation_id_for(repo))
  end

  # All installations (orgs/users) where this App is installed.
  def installations
    resp = app_conn.get("/app/installations")
    raise Error, error_message(resp) unless resp.success?

    JSON.parse(resp.body).map { |i| { account: i.dig("account", "login"), id: i["id"], repos: i["repository_selection"] } }
  end

  private

  def b64(data)
    Base64.urlsafe_encode64(data, padding: false)
  end

  def app_conn
    Faraday.new(url: BASE) do |f|
      f.headers["Authorization"] = "Bearer #{app_jwt}"
      f.headers["Accept"] = "application/vnd.github+json"
      f.headers["X-GitHub-Api-Version"] = "2022-11-28"
      f.headers["User-Agent"] = "Conductor"
      f.options.timeout = 15
    end
  end

  def error_message(resp)
    body = JSON.parse(resp.body) rescue {}
    "GitHub App API #{resp.status}: #{body["message"] || resp.body.to_s[0, 120]}"
  end
end
