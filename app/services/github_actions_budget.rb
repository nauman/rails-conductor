require "net/http"
require "json"

# How many GitHub Actions minutes are left, asked BEFORE a build is placed there.
#
# The alternative — place the build on CI and find out by failing — spends a deploy
# to learn a number GitHub will simply tell you. It also produces the worst kind of
# failure: one that looks like a broken build but is really a broken bill.
#
# Public repositories do not consume minutes at all, so the common case needs no
# API call and no credential. That matters here: the fleet's own control plane is a
# public repo, and an integration that only works with a token would be off for the
# app that needs it least.
class GithubActionsBudget
  # Leave room rather than running to zero: a build placed with four minutes left
  # fails halfway and still bills for the attempt.
  RESERVE_MINUTES = 50

  def initialize(app, http: nil)
    @app = app
    @http = http
  end

  # { included:, used:, remaining:, blocked_by: } — blocked_by is nil when CI can
  # take the work, otherwise one of BuildPlacement::PLACEMENT_FAILURES.
  def status
    return { blocked_by: :no_workflow } unless workflow_present?
    return { included: :unlimited, remaining: :unlimited, blocked_by: nil } if public_repo?

    billing = fetch_billing
    return { blocked_by: :not_configured } if billing.nil?

    included  = billing["included_minutes"].to_i
    used      = billing["total_minutes_used"].to_i
    remaining = included - used
    { included: included, used: used, remaining: remaining,
      blocked_by: (remaining <= RESERVE_MINUTES ? :quota_exhausted : nil) }
  end

  private

  # Cheap and local: if Conductor has never seen a build workflow for this repo we
  # do not ask GitHub about minutes it would never spend.
  def workflow_present?
    @app.respond_to?(:ci_build_workflow) ? @app.ci_build_workflow.present? : @app.repository_url.present?
  end

  def public_repo? = @app.respond_to?(:public_repo?) && @app.public_repo?

  # Nil rather than raise: an unavailable billing API must not take a deploy down.
  # A nil answer degrades to "cannot place here", and the ladder moves on.
  def fetch_billing
    token = github_token
    return nil if token.blank?

    owner = @app.repository_url.to_s[%r{github\.com[:/]+([^/]+)/}, 1]
    return nil if owner.blank?

    response = get("https://api.github.com/orgs/#{owner}/settings/billing/actions", token) ||
               get("https://api.github.com/users/#{owner}/settings/billing/actions", token)
    response
  end

  def get(url, token)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/vnd.github+json"
    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) do |http|
      http.request(req)
    end
    res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
  rescue StandardError
    nil
  end

  def github_token
    @app.organization&.credentials&.find_by(provider: "github")&.api_key
  end
end
