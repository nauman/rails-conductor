require "test_helper"

# "The venue could not do the work" and "the work is broken" are different facts,
# and conflating them is expensive in both directions: falling back on a red build
# rebuilds a broken commit somewhere else, and NOT falling back on an exhausted
# quota stops a deploy with the message "the commit is broken" when the commit is
# fine.
class CiVenueClassificationTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cvc@example.com")
    org = Organization.create_for(user, name: "Acme")
    server = org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.99")
    @app = org.apps.create!(name: "appone", slug: "appone", server: server, deploy_method: "kamal",
                            port: 3000, repository_url: "https://github.com/acme/appone.git")
    @app.update!(ci_build_workflow: "build.yml")
  end

  def outcome_for(conclusion)
    build = GithubActionsBuild.new(@app)
    build.stub(:latest_run_for, { "conclusion" => conclusion, "html_url" => "https://example.com/run" }) do
      build.send(:await, "abc1234def5678")
    end
  end

  # THE BUG. When minutes run out mid-period GitHub dispatches the run and then
  # kills it before any job executes — conclusion "startup_failure". Nothing was
  # learned about the commit, so calling it broken stops a deploy that should have
  # fallen back to a machine we own.
  test "a run that never started is a venue failure, not a broken commit" do
    outcome = outcome_for("startup_failure")

    assert outcome.placement_failed?, "startup_failure means the run never ran"
    assert_not_equal :build_failed, outcome.reason
  end

  # Waiting on a human approval is likewise not a verdict on the code.
  test "a run awaiting approval is a venue failure" do
    assert outcome_for("action_required").placement_failed?
  end

  # And the other direction must not regress: a genuinely red build still stops.
  test "a failed build still stops the deploy" do
    outcome = outcome_for("failure")

    assert_equal :build_failed, outcome.status
    assert_not outcome.placement_failed?
  end

  test "a timed-out build still stops the deploy" do
    assert_equal :build_failed, outcome_for("timed_out").status
  end

  test "a successful run is ok" do
    assert outcome_for("success").ok?
  end
end
