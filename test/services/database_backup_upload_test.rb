require "test_helper"

# The upload path recorded success for uploads that never happened.
#
#   ssh.execute(cmd) ? true : fail_upload(...)
#
# SshConnection#execute returns the command's OUTPUT, not its exit status. A
# failed `aws s3 cp` returns its error text — a non-empty String, therefore
# truthy — so the backup was marked completed with a real size while the bucket
# stayed empty. The dump was genuine; the local copy was then deleted.
#
# Every backup in the fleet was in this state, undetected, because nothing ever
# asked the bucket whether the object was there.
class DatabaseBackupUploadTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    def initialize(responses = {})
      @responses = responses
      @commands = []
    end

    def execute(cmd)
      execute_with_status(cmd)[:output]
    end

    def execute_with_status(cmd)
      @commands << cmd
      key = @responses.keys.select { |k| cmd.include?(k.to_s) }.max_by { |k| k.to_s.length }
      v = key ? @responses[key] : { success: true, output: "" }
      @last_output = v[:output].to_s
      { success: v[:success], exit_code: v[:success] ? 0 : 255,
        output: @last_output, stderr: v[:stderr].to_s }
    end

    # The size probe reads `ssh.output` after `execute` — mirror the real object.
    def output = @last_output
    def error = "err"
  end

  setup do
    user = User.create!(email: "up@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   ssh_key: SshKey.create!(name: "k", private_key: valid_private_key,
                                                           organization: @org))
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare",
                                     api_key: "AK", api_secret: "SK", account_id: "a1")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "buck",
                                   credential: @cred, server: @server,
                                   schedule: "daily", enabled: true)
  end

  def happy
    {
      "pg_dump"   => { success: true, output: "" },
      "stat"      => { success: true, output: "5000000" },
      "aws s3 cp" => { success: true, output: "" },
      "aws s3 ls" => { success: true, output: "2026-08-03 03:00:01  5000000 buck_x.sql.gz" },
      "rm -f"     => { success: true, output: "" }
    }
  end

  def run_backup(responses)
    ssh = FakeSsh.new(responses)
    svc = DatabaseBackup.new(@backup, ssh: ssh)
    [ svc.run!, svc, ssh ]
  end

  test "a healthy backup completes" do
    ok, = run_backup(happy)

    assert ok
    assert_equal "completed", @backup.reload.status
  end

  # THE bug.
  test "an upload that fails is NOT recorded as a successful backup" do
    ok, svc = run_backup(happy.merge(
      "aws s3 cp" => { success: false, output: "Partial credentials found in env, missing: AWS_SECRET_ACCESS_KEY" }
    ))

    assert_not ok, "a failed upload must fail the backup"
    assert_equal "failed", @backup.reload.status
    assert_match(/partial credentials/i, svc.error.to_s)
  end

  # Exit 0 is the command's opinion; the bucket is the fact.
  test "an upload that exits 0 but stores nothing is a failure" do
    ok, svc = run_backup(happy.merge("aws s3 ls" => { success: false, output: "" }))

    assert_not ok
    assert_match(/not found in bucket/i, svc.error.to_s)
    assert_equal "failed", @backup.reload.status
  end

  test "an object listed with a zero size is a failure" do
    ok, svc = run_backup(happy.merge(
      "aws s3 ls" => { success: true, output: "2026-08-03 03:00:01  0 buck_x.sql.gz" }
    ))

    assert_not ok
    assert_match(/0 bytes/i, svc.error.to_s)
  end

  test "the bucket is actually asked, after the copy" do
    _, _, ssh = run_backup(happy)

    assert ssh.commands.any? { |c| c.include?("aws s3 ls") },
           "an upload nobody confirms is an assumption, not a backup"
  end

  # A dump that exits non-zero must fail even if it wrote a plausible file.
  test "a dump command that exits non-zero fails the backup" do
    ok, = run_backup(happy.merge("pg_dump" => { success: false, stderr: "server version mismatch" }))

    assert_not ok
    assert_equal "failed", @backup.reload.status
  end

  test "a local-provider backup skips upload entirely" do
    @backup.update!(provider: "local")
    _, _, ssh = run_backup(happy)

    assert ssh.commands.none? { |c| c.include?("aws s3") }
  end
end
