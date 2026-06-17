require "test_helper"

class CronJobsTest < ActionDispatch::IntegrationTest
  def sign_in_as(user)
    user.organizations.update_all(onboarded_at: Time.current)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  # Stub CrontabClient so requests never hit a real server over SSH.
  def with_fake_crontab
    fake = Object.new
    def fake.upsert_job(**) = { "action" => "upserted" }
    def fake.remove_job(**) = { "action" => "removed" }
    CrontabClient.stub(:new, fake) { yield }
  end

  setup do
    @user = User.create!(email: "owner@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "s1", status: "online")
    sign_in_as(@user)
  end

  test "create a scheduled job installs it and scopes it to the org and server" do
    with_fake_crontab do
      assert_difference -> { @org.cron_jobs.count }, 1 do
        post server_cron_jobs_path(@server), params: { cron_job: {
          name: "Nightly audit", schedule: "every day at 3am", command: "/usr/bin/server-audit"
        } }
      end
    end

    job = @org.cron_jobs.last
    assert_equal @server, job.server
    assert_equal "0 3 * * *", job.cron_expression
    assert_redirected_to server_path(@server)
  end

  test "an unparseable schedule is rejected without creating a job" do
    with_fake_crontab do
      assert_no_difference -> { @org.cron_jobs.count } do
        post server_cron_jobs_path(@server), params: { cron_job: {
          name: "Bad", schedule: "whenever", command: "/x"
        } }
      end
    end
    assert_redirected_to server_path(@server)
  end

  test "toggling a job flips its status" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/x", schedule: "0 3 * * *")

    with_fake_crontab do
      patch server_cron_job_path(@server, job)
    end

    assert_equal "disabled", job.reload.status
  end

  test "deleting a job removes the record" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/x", schedule: "0 3 * * *")

    with_fake_crontab do
      assert_difference -> { @org.cron_jobs.count }, -1 do
        delete server_cron_job_path(@server, job)
      end
    end
  end

  test "one-click schedules a built-in maintenance script onto the server" do
    script = Script.create!(name: "server-audit", script_type: "maintenance", built_in: true,
      body: "#!/bin/bash\necho audit\n", description: "Security audit")

    installer = Object.new
    def installer.install(name:, body:) = "/usr/local/bin/conductor-server-audit"

    with_fake_crontab do
      ScriptInstaller.stub(:new, installer) do
        assert_difference -> { @org.cron_jobs.count }, 1 do
          post schedule_script_server_cron_jobs_path(@server), params: { script_id: script.id, schedule: "every day at 4am" }
        end
      end
    end

    job = @org.cron_jobs.last
    assert_equal "/usr/local/bin/conductor-server-audit", job.command
    assert_equal "0 4 * * *", job.cron_expression
    assert_redirected_to server_path(@server)
  end

  test "cannot manage cron jobs on another org's server" do
    other = Organization.create!(name: "Other")
    theirs = other.servers.create!(name: "theirs", status: "online")

    assert_no_difference -> { CronJob.count } do
      post server_cron_jobs_path(theirs), params: { cron_job: { name: "x", schedule: "0 3 * * *", command: "/x" } }
    end
    assert_response :not_found
  end
end
