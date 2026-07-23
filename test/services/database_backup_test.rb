require "test_helper"

class DatabaseBackupTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "bk@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare",
                                     api_key: "R2_ACCESS_KEY", api_secret: "R2_SECRET", account_id: "acct123")
    @backup = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "mybucket",
                                   credential: @cred, status: "pending")
  end

  test "R2 upload targets the account-id endpoint + region auto — never the secret as host" do
    captured = nil
    ssh = Object.new
    ssh.define_singleton_method(:execute) { |cmd| captured = cmd; true }

    DatabaseBackup.new(@backup).send(:upload_to_r2, ssh, "/tmp/db.sql.gz", "db.sql.gz")

    assert_includes captured, "https://acct123.r2.cloudflarestorage.com", "endpoint host must be the account id"
    refute_includes captured, "R2_SECRET.r2.cloudflarestorage.com", "the secret must not be the endpoint host"
    assert_includes captured, "AWS_DEFAULT_REGION=auto", "R2 needs region auto"
    assert_includes captured, "AWS_ACCESS_KEY_ID=R2_ACCESS_KEY"
    assert_includes captured, "s3://mybucket/db.sql.gz"
  end
end
