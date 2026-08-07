require "test_helper"

# `retention_days` was displayed on every backup ("14 days") and enforced by
# nothing. Objects accumulated forever — a promise the UI made and the system
# did not keep.
#
# Pruning is the one part of a backup system that DESTROYS data, so the tests
# here are mostly about what it must refuse to delete.
class BackupRetentionTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    def initialize(listing)
      @listing = listing
      @commands = []
    end

    def execute_with_status(cmd)
      @commands << cmd
      if cmd.include?("list-objects-v2")
        { success: true, exit_code: 0, output: @listing, stderr: "" }
      else
        { success: true, exit_code: 0, output: "", stderr: "" }
      end
    end

    def deleted_keys
      @commands.select { |c| c.include?("s3 rm") }
               .map { |c| c[%r{s3://[^/]+/(\S+)}, 1] }
    end
  end

  setup do
    user = User.create!(email: "ret@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server)
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare",
                                     api_key: "AK", api_secret: "SK", account_id: "a1")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "buck",
                                   credential: @cred, server: @server, app: @app,
                                   schedule: "daily", enabled: true, retention_days: 14)
  end

  # `aws s3api list-objects-v2 --query 'Contents[].[Key,LastModified]' --output text`
  def listing(*rows)
    rows.map { |key, age| "#{key}\t#{age.ago.utc.iso8601}" }.join("\n")
  end

  def prune(ssh)
    BackupRetention.new(@backup, ssh: ssh).prune!
  end

  test "objects past the retention window are deleted" do
    ssh = FakeSsh.new(listing(
      [ "kuickr/kuickr_old.sql.gz", 40.days ],
      [ "kuickr/kuickr_new.sql.gz", 1.day ]
    ))

    res = prune(ssh)

    assert_equal [ "kuickr/kuickr_old.sql.gz" ], ssh.deleted_keys
    assert_equal 1, res.deleted
  end

  test "objects inside the window are kept" do
    ssh = FakeSsh.new(listing([ "kuickr/kuickr_a.sql.gz", 3.days ], [ "kuickr/kuickr_b.sql.gz", 13.days ]))

    prune(ssh)

    assert_empty ssh.deleted_keys
  end

  # THE important one. An app that stopped backing up (paused, broken, retired)
  # has only old objects. Honouring retention literally would delete the last
  # copy of its database — retention would become the thing that destroys the
  # backup it exists to manage.
  test "the newest object is never deleted, however old it is" do
    ssh = FakeSsh.new(listing(
      [ "kuickr/kuickr_ancient.sql.gz", 400.days ],
      [ "kuickr/kuickr_old.sql.gz", 300.days ]
    ))

    prune(ssh)

    assert_equal [ "kuickr/kuickr_ancient.sql.gz" ], ssh.deleted_keys,
                 "must keep kuickr_old — the most recent of the two — as the last line of defence"
  end

  # The listing is scoped by prefix, but a wrong prefix or a shared bucket makes
  # that a single mistake away from deleting another app's backups.
  test "nothing outside this app's prefix is ever deleted" do
    ssh = FakeSsh.new(listing(
      [ "starrrs/starrrs_old.sql.gz", 90.days ],
      [ "kuickr/kuickr_old.sql.gz", 90.days ],
      [ "kuickr/kuickr_new.sql.gz", 1.day ]
    ))

    prune(ssh)

    assert_equal [ "kuickr/kuickr_old.sql.gz" ], ssh.deleted_keys
  end

  test "only dump objects are touched" do
    ssh = FakeSsh.new(listing(
      [ "kuickr/notes.txt", 90.days ],
      [ "kuickr/kuickr_old.sql.gz", 90.days ],
      [ "kuickr/kuickr_new.sql.gz", 1.day ]
    ))

    prune(ssh)

    assert_equal [ "kuickr/kuickr_old.sql.gz" ], ssh.deleted_keys
  end

  test "retention_days unset means keep everything" do
    @backup.update_column(:retention_days, nil)
    ssh = FakeSsh.new(listing([ "kuickr/kuickr_old.sql.gz", 900.days ]))

    res = prune(ssh)

    assert_empty ssh.deleted_keys
    assert_equal 0, res.deleted
  end

  # A listing that fails must not be read as "the bucket is empty" — the same
  # class of bug as the upload that read an error string as success.
  test "a failed listing prunes nothing" do
    ssh = FakeSsh.new("")
    def ssh.execute_with_status(cmd)
      @commands << cmd
      { success: false, exit_code: 1, output: "", stderr: "denied" }
    end

    res = prune(ssh)

    assert_empty ssh.deleted_keys
    refute res.ok?
  end
end
