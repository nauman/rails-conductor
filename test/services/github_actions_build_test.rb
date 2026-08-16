require "test_helper"

class GithubActionsBuildTest < ActiveSupport::TestCase
  # REAL Net::HTTP response objects, not doubles. `case/when` dispatches on
  # Module#=== which inspects the actual type rather than calling #is_a?, so a
  # stand-in silently matches nothing and every branch falls to the else — which is
  # exactly how this test first "passed" the wrong way.
  CODES = { Net::HTTPOK => "200", Net::HTTPNoContent => "204", Net::HTTPForbidden => "403",
            Net::HTTPNotFound => "404", Net::HTTPUnauthorized => "401" }.freeze

  def self.res(klass, body = nil)
    response = klass.new("1.1", CODES.fetch(klass), klass.name)
    response.define_singleton_method(:body) { body.to_json }
    response
  end

  def res(klass, body = nil) = self.class.res(klass, body)

  class FakeHttp
    def initialize(&responder) = @responder = responder
    def start(*, **) = yield(self)
    def request(req) = @responder.call(req)
  end

  setup do
    user = User.create!(email: "gab@example.com")
    @org = Organization.create_for(user, name: "GAB")
    @org.credentials.create!(name: "gh", provider: "github", api_key: "ghp_test")
    server = @org.servers.create!(name: "box", status: "online", ip_address: "203.0.113.9")
    @app = @org.apps.create!(name: "CI App", slug: "ci-app", server: server, deploy_method: "kamal",
                             repository_url: "https://github.com/acme/ci-app.git", branch: "main",
                             ci_build_workflow: "build.yml")
  end

  test "an app that has not opted in is a placement failure, not an error" do
    @app.update!(ci_build_workflow: nil)

    outcome = GithubActionsBuild.new(@app).build!("abc1234")

    assert outcome.placement_failed?
    assert_equal :no_workflow, outcome.reason
    assert_includes BuildPlacement::PLACEMENT_FAILURES, outcome.reason
  end

  test "a refused dispatch falls back rather than failing the deploy" do
    http = FakeHttp.new { res(Net::HTTPForbidden) }

    outcome = GithubActionsBuild.new(@app, http: http).build!("abc1234")

    assert outcome.placement_failed?
    assert_equal :quota_exhausted, outcome.reason
    assert_includes outcome.detail, "quota"
  end

  test "a missing workflow in the repo is a venue problem" do
    http = FakeHttp.new { res(Net::HTTPNotFound) }

    assert_equal :no_workflow, GithubActionsBuild.new(@app, http: http).build!("abc1234").reason
  end

  # The distinction the whole fallback rests on. A red build must stop the deploy;
  # rebuilding it elsewhere reaches the same red having spent the fallback.
  test "a failed build is NOT a placement failure and must not fall through" do
    http = FakeHttp.new do |req|
      if req.is_a?(Net::HTTP::Post)
        res(Net::HTTPNoContent)
      else
        res(Net::HTTPOK, { "workflow_runs" => [ { "head_sha" => "abc1234", "conclusion" => "failure",
                                                      "html_url" => "https://github.com/acme/ci-app/runs/1" } ] })
      end
    end

    outcome = GithubActionsBuild.new(@app, http: http).build!("abc1234")

    assert_equal :build_failed, outcome.status
    refute outcome.placement_failed?, "a broken commit must not be retried on another machine"
    refute_includes BuildPlacement::PLACEMENT_FAILURES, outcome.reason
    assert_includes outcome.detail, "not the venue"
  end

  test "a cancelled run is a venue problem, because nobody judged the commit" do
    http = FakeHttp.new do |req|
      req.is_a?(Net::HTTP::Post) ? res(Net::HTTPNoContent) :
        res(Net::HTTPOK, { "workflow_runs" => [ { "head_sha" => "abc1234", "conclusion" => "cancelled" } ] })
    end

    outcome = GithubActionsBuild.new(@app, http: http).build!("abc1234")

    assert outcome.placement_failed?
    assert_equal :no_runner, outcome.reason
  end

  test "a successful run reports ok with the run url" do
    http = FakeHttp.new do |req|
      req.is_a?(Net::HTTP::Post) ? res(Net::HTTPNoContent) :
        res(Net::HTTPOK, { "workflow_runs" => [ { "head_sha" => "abc1234", "conclusion" => "success",
                                                      "html_url" => "https://github.com/acme/ci-app/runs/2" } ] })
    end

    outcome = GithubActionsBuild.new(@app, http: http).build!("abc1234")

    assert outcome.ok?
    assert_equal "https://github.com/acme/ci-app/runs/2", outcome.run_url
  end
end
