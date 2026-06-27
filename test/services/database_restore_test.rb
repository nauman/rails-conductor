require "test_helper"

# Slice 1 of roadmap slot 21 (docs/plans/postgres-restore.md): restore a chosen
# backup object from R2 into a target database, over SSH on the backup's server,
# streaming the log. Symmetric inverse of DatabaseBackup (pg_dump | gzip → R2).
class DatabaseRestoreTest < ActiveSupport::TestCase
  # SSH stub matching the slice of SshConnection that DatabaseRestore uses.
  class FakeSsh
    attr_reader :commands
    def initialize(download_success: true, restore_success: true)
      @download_success = download_success
      @restore_success = restore_success
      @commands = []
    end

    def execute_with_status(cmd)
      @commands << cmd
      success =
        if cmd.include?("aws s3 cp")
          @download_success
        elsif cmd.include?("psql")
          @restore_success
        else
          true
        end
      { success: success, exit_code: success ? 0 : 1,
        output: success ? "" : "boom", stdout: "", stderr: success ? "" : "boom" }
    end

    def execute(cmd) = (@commands << cmd; true)
    def output = ""
    def error = "boom"
  end

  setup do
    user = User.create!(email: "br@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "db", status: "online", ip_address: "9.9.9.9", ssh_key: key)
    @cred = Credential.create!(name: "r2", provider: "cloudflare",
                              api_key: "AKIA_R2", api_secret: "r2secret", organization: @org)
    @backup = Backup.create!(provider: "cloudflare_r2", bucket_name: "conductor-db",
                             credential: @cred, server: @server, organization: @org, status: "completed")
  end

  def restore(attrs = {})
    DatabaseRestore.new(@backup, **{
      object_key: "conductor-db_20260624_030000.sql.gz",
      target_url: "postgres://u:p@localhost/scratch_db"
    }.merge(attrs))
  end

  test "downloads the chosen object from R2 then restores into the target, succeeds" do
    ssh = FakeSsh.new
    SshConnection.stub(:new, ssh) do
      assert restore(ssh_override: ssh).run!
    end

    dl = ssh.commands.find { |c| c.include?("aws s3 cp") }
    assert dl, "expected an aws s3 cp download"
    assert_includes dl, "s3://conductor-db/conductor-db_20260624_030000.sql.gz"
    assert_includes dl, "--endpoint-url"

    rs = ssh.commands.find { |c| c.include?("psql") }
    assert rs, "expected a psql restore step"
    assert_includes rs, "gunzip", "backups are pg_dump | gzip, so restore must gunzip"
  end

  test "fails when no credential is configured" do
    @backup.update!(credential: nil)
    svc = restore
    refute svc.run!
    assert_match(/credential/i, svc.error)
  end

  test "fails when the server has no SSH access" do
    @server.update!(ssh_key: nil)
    svc = restore
    refute svc.run!
    assert_match(/SSH/i, svc.error)
  end

  test "a failed download fails the restore and skips psql" do
    ssh = FakeSsh.new(download_success: false)
    svc = nil
    SshConnection.stub(:new, ssh) do
      svc = restore(ssh_override: ssh)
      refute svc.run!
    end
    refute ssh.commands.any? { |c| c.include?("psql") }, "must not restore after a failed download"
    assert_match(/download/i, svc.error)
  end

  test "a failed psql restore fails the operation" do
    ssh = FakeSsh.new(restore_success: false)
    svc = nil
    SshConnection.stub(:new, ssh) do
      svc = restore(ssh_override: ssh)
      refute svc.run!
    end
    assert_match(/restore/i, svc.error)
  end

  test "requires an object_key and a target_url" do
    refute restore(object_key: nil).run!
    refute restore(target_url: nil).run!
  end
end
