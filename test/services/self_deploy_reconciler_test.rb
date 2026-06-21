require "test_helper"

# When Conductor deploys ITSELF, `kamal deploy` boots the new container and stops
# the old one — the old one being where DeployAppJob runs. The job is killed
# before it can mark the deployment succeeded. SelfDeployReconciler runs on the
# NEW container's boot: it finalizes any in-progress self-managed deployment by
# matching the deployed git sha (kamal injects it as KAMAL_VERSION).
class SelfDeployReconcilerTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @app = @org.apps.create!(name: "Conductor", slug: "conductor",
                             deploy_method: "kamal", self_managed: true)
  end

  test "marks an in-progress self-deploy succeeded when the running version matches its commit" do
    dep = @app.deployments.create!(status: "deploying", started_at: 2.minutes.ago, commit_sha: "abc123def456")

    SelfDeployReconciler.run(version: "abc123def456")

    assert_equal "succeeded", dep.reload.status
    assert_equal "running", @app.reload.status
    assert_includes dep.log.to_s, "reconciled"
  end

  test "matches when the running version is a short prefix of the recorded sha" do
    dep = @app.deployments.create!(status: "deploying", started_at: 1.minute.ago, commit_sha: "abc123def4567890")

    SelfDeployReconciler.run(version: "abc123d") # kamal short sha

    assert_equal "succeeded", dep.reload.status
  end

  test "fails a stale in-progress self-deploy whose version never came up" do
    dep = @app.deployments.create!(status: "deploying", started_at: 40.minutes.ago, commit_sha: "oldsha000")

    SelfDeployReconciler.run(version: "newsha999")

    assert_equal "failed", dep.reload.status
    assert_match(/replaced|did not complete|timed out/i, dep.log.to_s)
  end

  test "leaves a recent non-matching in-progress deploy alone (still building/deploying)" do
    dep = @app.deployments.create!(status: "deploying", started_at: 30.seconds.ago, commit_sha: "pending123")

    SelfDeployReconciler.run(version: "different999")

    assert_equal "deploying", dep.reload.status
  end

  test "ignores deployments of non-self-managed apps" do
    other = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal", self_managed: false)
    dep = other.deployments.create!(status: "deploying", started_at: 2.minutes.ago, commit_sha: "match123")

    SelfDeployReconciler.run(version: "match123")

    assert_equal "deploying", dep.reload.status, "must not touch other apps' deployments"
  end

  test "no-ops when version is blank (not running a kamal release)" do
    dep = @app.deployments.create!(status: "deploying", started_at: 2.minutes.ago, commit_sha: "abc123")

    assert_nothing_raised { SelfDeployReconciler.run(version: nil) }
    assert_equal "deploying", dep.reload.status
  end

  test "ignores already-finished deployments" do
    dep = @app.deployments.create!(status: "succeeded", started_at: 2.minutes.ago,
                                   completed_at: 1.minute.ago, commit_sha: "abc123")

    SelfDeployReconciler.run(version: "abc123")

    assert_equal "succeeded", dep.reload.status
  end
end
