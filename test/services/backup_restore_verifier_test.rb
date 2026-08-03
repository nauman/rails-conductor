require "test_helper"

# "We take backups" is not a guarantee. "We restored last night's dump into a
# clean postgres and it came back with 187 tables" is.
#
# Before this, every backup in the fleet read `never_tested` — ten green
# schedules and zero evidence any of them could be restored. The 0-byte guard
# catches an empty dump; nothing caught a dump that uploads fine and will not
# restore.
class BackupRestoreVerifierTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    # responses: substring => output (or :fail to make that command fail)
    def initialize(responses = {})
      @responses = responses
      @commands = []
    end

    def execute_with_status(cmd)
      @commands << cmd
      key = @responses.keys.select { |k| cmd.include?(k.to_s) }.max_by { |k| k.to_s.length }
      value = key ? @responses[key] : ""
      return { success: false, output: "", stderr: "boom" } if value == :fail

      { success: true, output: value, stderr: "" }
    end
  end

  setup do
    user = User.create!(email: "verify@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare",
                                     api_key: "AK", api_secret: "SK", account_id: "acct1")
    @app = @org.apps.create!(name: "InventList", slug: "inventlist", server: @server,
                             deploy_method: "docker", port: 3000,
                             repository_url: "https://github.com/x/y.git")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "mybucket",
                                   credential: @cred, server: @server, app: @app,
                                   schedule: "daily", enabled: true)
    @run = @backup.record_dispatch!(trigger: "scheduled")
    @run.start!
    @run.complete!(size_bytes: 5_000_000, object_key: "mybucket_20260803_030000.sql.gz")
  end

  # A restore that reports success while producing an empty database is the same
  # trap as a 0-byte dump reporting success.
  def healthy_responses
    {
      "aws s3 cp"     => "download: s3://mybucket/... to /tmp/...",
      "pg_isready"    => "accepting connections",
      "gunzip"        => "",
      # Match on fragments that survive Shellwords.escape — the SQL reaches the
      # shell as `select\ count\(\*\)\ from\ information_schema.tables`.
      "pg_database"   => "inventlist_production",
      "information_schema.tables" => "187",
      "n_live_tup"    => "42000"
    }
  end

  def verify(responses)
    ssh = FakeSsh.new(responses)
    [ BackupRestoreVerifier.new(@backup, ssh: ssh).verify!, ssh ]
  end

  test "a restorable dump is recorded as verified with what was actually found" do
    result, = verify(healthy_responses)

    assert_equal "verified", result.status
    assert_equal 187, result.tables
    @backup.reload
    assert_equal "verified", @backup.verification_status
    assert @backup.verified_at.present?
    assert_match "187", @backup.verification_note
  end

  # THE point. A dump that restores into zero tables is not a backup.
  test "a restore producing no tables is a FAILURE, not a pass" do
    result, = verify(healthy_responses.merge("information_schema.tables" => "0"))

    assert_equal "failed", result.status
    assert_match(/no tables/i, result.detail)
    assert_equal "failed", @backup.reload.verification_status
  end

  test "a download that fails is recorded as failed, never as verified" do
    result, = verify(healthy_responses.merge("aws s3 cp" => :fail))

    assert_equal "failed", result.status
    assert_match(/download/i, result.detail)
    assert_equal "failed", @backup.reload.verification_status
  end

  test "a restore command that errors is recorded as failed" do
    result, = verify(healthy_responses.merge("gunzip" => :fail))

    assert_equal "failed", result.status
    assert_equal "failed", @backup.reload.verification_status
  end

  # Safety. The whole feature is worthless — worse than worthless — if verifying
  # a backup can touch the live database.
  test "the restore happens in a THROWAWAY container, never against the live cluster" do
    _, ssh = verify(healthy_responses)
    joined = ssh.commands.join("\n")

    assert_match(/docker run -d --name conductor-verify-/, joined,
                 "must spin up its own postgres")

    # The real DB container may be READ, to match the postgres version (a pg18
    # dump will not restore into pg16). What must never happen is a write path
    # into it: every psql/restore command must target the throwaway container.
    writes = joined.lines.select { |l| l.match?(/psql|gunzip|pg_isready/) }
    assert writes.any?, "sanity: there should be restore commands to inspect"
    writes.each do |line|
      assert_match(/conductor-verify-/, line, "restore command must target the throwaway: #{line}")
      assert_no_match(/inventlist-db/, line, "must never restore into the live database: #{line}")
    end

    assert_no_match(/dropdb|DROP DATABASE/i, joined,
                    "verification never drops anything that isn't its own container")
  end

  test "the throwaway container and downloaded dump are always cleaned up" do
    _, ssh = verify(healthy_responses)
    joined = ssh.commands.join("\n")

    assert_match(/docker rm -f conductor-verify-/, joined)
    assert_match(%r{rm -f /tmp/conductor-verify-}, joined)
  end

  test "cleanup still runs when the restore fails" do
    _, ssh = verify(healthy_responses.merge("gunzip" => :fail))

    assert_match(/docker rm -f conductor-verify-/, ssh.commands.join("\n"),
                 "a failed verification must not leak a container onto the box")
  end

  test "credentials are passed as env, and the vendor endpoint is used" do
    _, ssh = verify(healthy_responses)
    cp = ssh.commands.find { |c| c.include?("aws s3 cp") }

    assert_match "AWS_ACCESS_KEY_ID=AK", cp
    assert_match "s3://mybucket/mybucket_20260803_030000.sql.gz", cp
    assert_match "acct1.r2.cloudflarestorage.com", cp
  end

  test "a backup with no verifiable run is skipped rather than guessed at" do
    BackupRun.update_all(object_key: nil)

    result, ssh = verify(healthy_responses)

    assert_equal "skipped", result.status
    assert_empty ssh.commands, "must not touch the box when there is nothing to verify"
    assert_equal "never_tested", @backup.reload.verification_status,
                 "skipping is not a failure — nothing was tested"
  end
end
