require "test_helper"

class AppRollbackTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "rollback@example.com")
    @org = Organization.create_for(@user, name: "Rollback")
    @org.update!(onboarded_at: Time.current)
    key = SshKey.create!(name: "rb-key", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "rb-host", status: "online", ip_address: "10.0.0.31",
                                   ssh_key: key, ssh_user: "deploy")
    @app_rec = @org.apps.create!(name: "Rollback app", slug: "rollback-app", server: @server,
                             deploy_method: "kamal", repository_url: "https://github.com/x/y.git")
    # A prior successful release + a newer current release. Both stamped with the
    # runtime they shipped under — an unstamped row is "unknown runtime" and is
    # deliberately NOT a rollback target.
    @prior   = @app_rec.deployments.create!(status: "succeeded", release_version: "old111old111",
                                            deploy_method: "kamal", completed_at: 2.hours.ago)
    @current = @app_rec.deployments.create!(status: "succeeded", release_version: "new222new222",
                                            deploy_method: "kamal", completed_at: 1.hour.ago)

    session = Passwordless::Session.create!(authenticatable: @user)
    get "/users/sign_in/#{session.identifier}/#{session.token}"
  end

  test "rolling back to a prior release enqueues RollbackAppJob and records a rollback deployment" do
    assert_enqueued_with(job: RollbackAppJob) do
      post rollback_deployment_path(@prior)
    end
    rb = @app_rec.deployments.order(:created_at).last
    assert_equal "rollback", rb.kind
    assert_equal "old111old111", rb.release_version
    assert_redirected_to app_path(@app_rec)
  end

  test "cannot roll back to the current (latest successful) release" do
    assert_no_enqueued_jobs do
      post rollback_deployment_path(@current)
    end
    follow_redirect!
    assert_includes response.body, "current release"
  end

  test "rollback is refused while a deploy is already in progress" do
    @app_rec.deployments.create!(status: "deploying")
    assert_no_enqueued_jobs do
      post rollback_deployment_path(@prior)
    end
    follow_redirect!
    assert_includes response.body, "already in progress"
  end

  # Docker apps roll back now (ADR 0003 — releases are SHA-tagged and retained).
  test "docker apps can roll back" do
    AppFormChange.new(@app_rec).apply!(deploy_method: "docker")
    @prior.update!(deploy_method: "docker") # a release shipped under the new runtime
    assert_enqueued_with(job: RollbackAppJob) do
      post rollback_deployment_path(@prior)
    end
  end

  # A Kamal-era version names no local docker image, so offering it would produce
  # a rollback that cannot possibly succeed.
  test "a release from a previous runtime is NOT a rollback target" do
    AppFormChange.new(@app_rec).apply!(deploy_method: "docker") # @prior stays stamped "kamal"

    assert_not @prior.reload.rollback_target?
    assert_no_enqueued_jobs { post rollback_deployment_path(@prior) }
  end

  test "an unstamped release is treated as unknown runtime, not compatible" do
    @prior.update_columns(deploy_method: nil)

    assert_not @prior.reload.rollback_target?
  end

  test "native apps still refuse rollback — no release-dir rollback yet" do
    AppFormChange.new(@app_rec).apply!(deploy_method: "native")
    @prior.update!(deploy_method: "native")
    assert_no_enqueued_jobs do
      post rollback_deployment_path(@prior)
    end
    follow_redirect!
    assert_includes response.body, "native apps"
  end
end
