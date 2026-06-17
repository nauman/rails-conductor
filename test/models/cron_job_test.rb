require "test_helper"

class CronJobTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cron@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "s1", status: "offline")
  end

  test "resolves a friendly schedule to a cron expression on save" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/usr/bin/server-audit", schedule: "every day at 3am")

    assert_equal "0 3 * * *", job.cron_expression
    assert job.enabled?
  end

  test "keeps a raw cron expression intact" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/x", schedule: "0 2 * * *")

    assert_equal "0 2 * * *", job.cron_expression
  end

  test "is invalid when the schedule cannot be parsed" do
    job = @org.cron_jobs.new(server: @server, name: "Bad", command: "/x", schedule: "whenever")

    refute job.valid?
    assert_includes job.errors[:schedule].join, "valid schedule"
  end

  test "validates status inclusion" do
    job = @org.cron_jobs.new(server: @server, name: "x", command: "/x", schedule: "0 3 * * *", status: "bogus")

    refute job.valid?
    assert job.errors[:status].any?
  end

  test "crontab_id is derived from the record id" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/x", schedule: "0 3 * * *")

    assert_equal "cron-#{job.id}", job.crontab_id
  end

  test "install! upserts the resolved entry through the crontab client" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/usr/bin/server-audit", schedule: "every day at 3am")
    client = Minitest::Mock.new
    client.expect(:upsert_job, { "action" => "upserted" },
      id: "cron-#{job.id}", name: "Audit", cron_expression: "0 3 * * *", command: "/usr/bin/server-audit", enabled: true)

    job.install!(client: client)
    assert client.verify
  end

  test "uninstall! removes the managed block through the crontab client" do
    job = @org.cron_jobs.create!(server: @server, name: "Audit", command: "/x", schedule: "0 3 * * *")
    client = Minitest::Mock.new
    client.expect(:remove_job, { "action" => "removed" }, id: "cron-#{job.id}")

    job.uninstall!(client: client)
    assert client.verify
  end
end
