require "test_helper"

class DatabaseBackupTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "bk@example.com")
    @org = Organization.create_for(user, name: "Acme")
  end

  def backup_for(provider, cred_attrs)
    cred = @org.credentials.create!({ name: "c", provider: "cloudflare", api_key: "AK", api_secret: "SK" }.merge(cred_attrs))
    @org.backups.create!(provider: provider, bucket_name: "mybucket", credential: cred, status: "pending")
  end

  def cmd_for(provider, cred_attrs = {})
    b = backup_for(provider, cred_attrs)
    DatabaseBackup.new(b).send(:s3_upload_command, BackupVendors[provider], "/tmp/db.sql.gz", "db.sql.gz")
  end

  test "R2 targets the account-id endpoint + region auto — never the secret as host" do
    c = cmd_for("cloudflare_r2", account_id: "acct123")
    assert_includes c, "https://acct123.r2.cloudflarestorage.com"
    refute_includes c, "SK.r2.cloudflarestorage.com"
    assert_includes c, "AWS_DEFAULT_REGION=auto"
    assert_includes c, "s3://mybucket/db.sql.gz"
  end

  test "AWS S3 uses no custom endpoint (default) + the given region" do
    c = cmd_for("aws_s3", region: "eu-west-1")
    refute_includes c, "--endpoint-url"
    assert_includes c, "AWS_DEFAULT_REGION=eu-west-1"
  end

  test "Wasabi builds the regional wasabisys endpoint" do
    c = cmd_for("wasabi", region: "eu-central-1")
    assert_includes c, "--endpoint-url https://s3.eu-central-1.wasabisys.com"
  end

  test "MinIO / custom uses the credential's endpoint verbatim" do
    c = cmd_for("minio", endpoint: "https://minio.internal:9000", region: "us-east-1")
    assert_includes c, "--endpoint-url https://minio.internal:9000"
  end

  test "an unknown provider is a clean failure, not a crash" do
    b = backup_for("aws_s3", {})
    b.update_column(:provider, "bogus")
    svc = DatabaseBackup.new(b)
    fake_ssh = Object.new
    assert_not svc.send(:upload_to_storage, fake_ssh, "/tmp/x", "x")
    assert_match(/Unsupported provider/, svc.error)
  end

  test "local provider uploads nothing" do
    b = backup_for("aws_s3", {})
    b.update_column(:provider, "local")
    assert DatabaseBackup.new(b).send(:upload_to_storage, Object.new, "/tmp/x", "x")
  end

  # The dump-source fix: kamal apps hold DATABASE_URL in the CONTAINER, so a host
  # `pg_dump $DATABASE_URL` (host env is empty, verified on the fleet) backs up
  # nothing. Dump from inside the running web container instead.
  test "kamal app dumps from inside the running container, not the host shell" do
    app = @org.apps.create!(name: "k", slug: "k", deploy_method: "kamal", repository_url: "https://x/y.git")
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk", status: "pending", app: app)
    cmd = DatabaseBackup.new(b).send(:build_dump_command, "/tmp/x.sql.gz")

    assert_includes cmd, "docker exec"
    assert_includes cmd, "label=service="
    assert_includes cmd, "role=web"
    assert_includes cmd, %(pg_dump "$DATABASE_URL")
    assert_includes cmd, "gzip > /tmp/x.sql.gz"
  end

  test "native app keeps the host-env DATABASE_URL dump" do
    app = @org.apps.create!(name: "n", slug: "n", deploy_method: "native", repository_url: "https://x/y.git")
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk", status: "pending", app: app)
    cmd = DatabaseBackup.new(b).send(:build_dump_command, "/tmp/x.sql.gz")

    assert_equal "pg_dump $DATABASE_URL | gzip > /tmp/x.sql.gz", cmd
  end
end
