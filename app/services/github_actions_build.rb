require "net/http"
require "json"

# Build this commit on GitHub Actions, and report back honestly about what happened.
#
# The contract that matters is the one BuildPlacement depends on: distinguish a venue
# that cannot run the work from work that failed. Dispatch refused, no runner, no
# workflow, bad credentials → :placement_failed, and the caller drops to the next rung.
# The build ran and went red → :build_failed, and the deploy stops there. Retrying a
# compile error on another machine reaches the same red, slower, having spent the
# resource the fallback existed to protect.
class GithubActionsBuild
  Outcome = Struct.new(:status, :reason, :run_url, :detail, keyword_init: true) do
    def ok? = status == :ok
    def placement_failed? = status == :placement_failed
  end

  POLL_INTERVAL = 10
  MAX_WAIT = 20.minutes

  def initialize(app, http: nil, clock: nil)
    @app = app
    @http = http
    @clock = clock || -> { Time.current }
  end

  # Dispatch and wait. Returns an Outcome; never raises into a deploy.
  def build!(sha, wait: true)
    return refuse(:no_workflow, "no CI build workflow recorded for this app") if workflow.blank?
    return refuse(:not_configured, "no GitHub credential for this organization") if token.blank?
    return refuse(:not_configured, "repository_url is not a GitHub URL") if repo.blank?

    dispatched = dispatch(sha)
    return dispatched unless dispatched.ok?
    return dispatched unless wait

    await(sha)
  end

  private

  def dispatch(sha)
    res = post("https://api.github.com/repos/#{repo}/actions/workflows/#{workflow}/dispatches",
               { ref: default_branch, inputs: { sha: sha } })
    case res
    when Net::HTTPNoContent, Net::HTTPSuccess
      Outcome.new(status: :ok, detail: "dispatched #{workflow} for #{sha[0, 7]}")
    when Net::HTTPNotFound
      # The workflow or repo is not there — a venue problem, not a build problem.
      refuse(:no_workflow, "#{workflow} not found in #{repo}")
    when Net::HTTPUnauthorized, Net::HTTPForbidden
      # 403 also covers "billing/quota" and "actions disabled" — all reasons the
      # venue cannot take the work, all correctly a fallback rather than a failure.
      refuse(:quota_exhausted, "GitHub refused the dispatch (#{res.code}) — quota, permissions or Actions disabled")
    else
      refuse(:unreachable, "dispatch failed (#{res&.code || 'no response'})")
    end
  end

  def await(sha)
    deadline = @clock.call + MAX_WAIT
    loop do
      run = latest_run_for(sha)
      if run.nil?
        return refuse(:no_runner, "no run appeared for #{sha[0, 7]}") if @clock.call > deadline

        sleep POLL_INTERVAL
        next
      end

      case run["conclusion"]
      when nil # still running
        return refuse(:no_runner, "run did not finish within #{MAX_WAIT.inspect}") if @clock.call > deadline

        sleep POLL_INTERVAL
      when "success"
        return Outcome.new(status: :ok, run_url: run["html_url"], detail: "CI built and pushed #{sha[0, 7]}")
      when "cancelled", "skipped", "stale"
        # Nobody decided this commit is bad — the venue simply did not do the work.
        return refuse(:no_runner, "run #{run['conclusion']}", run["html_url"])
      else
        # failure / timed_out: the build itself is red. This must NOT fall through.
        return Outcome.new(status: :build_failed, reason: :build_failed, run_url: run["html_url"],
                           detail: "CI build #{run['conclusion']} — the commit is broken, not the venue")
      end
    end
  end

  def latest_run_for(sha)
    body = get_json("https://api.github.com/repos/#{repo}/actions/workflows/#{workflow}/runs?per_page=20")
    Array(body && body["workflow_runs"]).find { |r| r["head_sha"] == sha || r["display_title"].to_s.include?(sha[0, 7]) }
  end

  def refuse(reason, detail, url = nil)
    Outcome.new(status: :placement_failed, reason: reason, detail: detail, run_url: url)
  end

  def workflow = @app.try(:ci_build_workflow)
  def default_branch = @app.branch.presence || "main"
  def repo = @app.repository_url.to_s[%r{github\.com[:/]+([^/]+/[^/.]+)}, 1]
  def token = @app.organization&.credentials&.find_by(provider: "github")&.api_key

  def post(url, payload)
    uri = URI(url)
    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/vnd.github+json"
    req.body = payload.to_json
    (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
  rescue StandardError
    nil
  end

  def get_json(url)
    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    req["Authorization"] = "Bearer #{token}"
    req["Accept"] = "application/vnd.github+json"
    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 10) { |h| h.request(req) }
    res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : nil
  rescue StandardError
    nil
  end
end
