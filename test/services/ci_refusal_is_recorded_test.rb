require "test_helper"

# A venue that cannot take the work is not an error: the build falls back and the
# deploy goes green. But a PERMANENT refusal — an invalid workflow file, Actions
# switched off — then repeats forever behind those green deploys, visible only as
# one line in a log nobody re-reads. The fallback is right; the silence is not.
class CiRefusalIsRecordedTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "cir@example.com")
    org = Organization.create_for(@user, name: "Acme")
    server = org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.130")
    @app = org.apps.create!(name: "appone", slug: "appone", server: server, deploy_method: "kamal",
                            port: 3000, repository_url: "https://github.com/x/y.git")
    @app.update!(ci_build_workflow: "build.yml")
  end

  test "a refusal is recorded so a repeated one can be seen" do
    @app.record_ci_refusal!(:quota_exhausted, "run failed to start")

    assert_equal "quota_exhausted", @app.reload.ci_refused_reason
    assert @app.ci_refused_at.present?
    assert_match(/failed to start/, @app.ci_refused_detail)
  end

  # Otherwise the record becomes its own stale fact (ADR 0010) — a fault that was
  # fixed weeks ago still reading as current.
  test "a successful CI build clears the recorded fault" do
    @app.record_ci_refusal!(:quota_exhausted, "run failed to start")

    @app.clear_ci_refusal!

    assert_nil @app.reload.ci_refused_reason
    assert_nil @app.ci_refused_at
  end

  test "a refusal that keeps happening is reported as persistent" do
    @app.record_ci_refusal!(:quota_exhausted, "run failed to start")
    @app.update_columns(ci_refused_at: 8.days.ago)

    assert @app.reload.ci_refusal_persistent?,
           "a refusal still standing after a week is a fault, not a blip"
  end

  test "a fresh refusal is not yet persistent" do
    @app.record_ci_refusal!(:quota_exhausted, "run failed to start")

    assert_not @app.reload.ci_refusal_persistent?
  end
end
