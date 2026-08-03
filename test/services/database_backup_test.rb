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

  # Best source: the dedicated DB container — exact server version (incl. pg18),
  # local, and running even when the app is stopped. pg_dumpall = all dbs + roles.
  test "dumps from the dedicated DB container when one is running" do
    app = @org.apps.create!(name: "calm-page", slug: "calm-page", deploy_method: "kamal", repository_url: "https://x/y.git")
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk-backups", status: "pending", app: app)
    ssh = Object.new
    ssh.define_singleton_method(:execute) { |cmd| @o = cmd.include?("docker ps -q -f name=") ? "abc123" : ""; true }
    ssh.define_singleton_method(:output) { @o }
    cmd = DatabaseBackup.new(b).send(:build_dump_command, ssh, "/tmp/x.sql.gz")

    assert_includes cmd, "docker exec calm-page-db"
    assert_includes cmd, "pg_dumpall"
    assert_includes cmd, "POSTGRES_USER:-postgres" # superuser fallback for images that leave it unset
    assert_includes cmd, "gzip > /tmp/x.sql.gz"
  end

  # Shared-cluster apps have no dedicated container — resolve the DSN and dump
  # version-matched on the app network.
  test "shared app (no dedicated container) dumps version-matched on the network" do
    app = @org.apps.create!(name: "kuickr", slug: "kuickr", deploy_method: "kamal", repository_url: "https://x/y.git")
    app.define_singleton_method(:derived_database_url) { |*| nil }
    app.define_singleton_method(:deploy_network) { "kamal" }
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk-backups", status: "pending", app: app)
    ssh = Object.new
    ssh.define_singleton_method(:execute) do |cmd|
      @o = if cmd.include?("docker ps -q -f name=") then ""
           elsif cmd.include?("printenv") then ""
           else "CONDUCTOR_DSN=postgres://u:p@conductor-postgres:5432/kdb" end
      true
    end
    ssh.define_singleton_method(:output) { @o }
    cmd = DatabaseBackup.new(b).send(:build_dump_command, ssh, "/tmp/x.sql.gz")

    assert_includes cmd, "docker run --rm --network kamal"
    assert_includes cmd, "postgres:16-alpine"
    assert_includes cmd, "conductor-postgres:5432/kdb"
    assert_includes cmd, "| gzip > /tmp/x.sql.gz"
    refute_includes cmd, "docker exec" # not the dedicated path
  end

  test "native app (no dedicated container, no resolvable url) falls back to host DATABASE_URL" do
    app = @org.apps.create!(name: "n", slug: "n", deploy_method: "native", repository_url: "https://x/y.git")
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk-backups", status: "pending", app: app)
    ssh = Object.new
    ssh.define_singleton_method(:execute) { |*| @o = ""; true }
    ssh.define_singleton_method(:output) { @o }
    cmd = DatabaseBackup.new(b).send(:build_dump_command, ssh, "/tmp/x.sql.gz")

    assert_equal %(pg_dump "$DATABASE_URL" | gzip > /tmp/x.sql.gz), cmd
    refute_includes cmd, "docker run"
  end

  # Shared/unregistered apps have no derived URL — read it from the container.
  test "resolve_database_url reads the url from the app container when Conductor has none" do
    app = @org.apps.create!(name: "k", slug: "k", deploy_method: "kamal", repository_url: "https://x/y.git")
    app.define_singleton_method(:derived_database_url) { |*| nil }
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk-backups", status: "pending", app: app)

    captured = nil
    fake_ssh = Object.new
    fake_ssh.define_singleton_method(:execute) { |cmd| captured = cmd; true }
    fake_ssh.define_singleton_method(:output) { "postgres://from-container/db\n" }

    url = DatabaseBackup.new(b).send(:resolve_database_url, fake_ssh)

    assert_equal "postgres://from-container/db", url
    assert_includes captured, "printenv DATABASE_URL"
    assert_includes captured, "label=service="
  end

  test "resolve_database_url prefers a known derived url and does not touch ssh" do
    app = @org.apps.create!(name: "k2", slug: "k2", deploy_method: "kamal", repository_url: "https://x/y.git")
    app.define_singleton_method(:derived_database_url) { |*| "postgres://derived/db" }
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk-backups", status: "pending", app: app)
    fake_ssh = Object.new
    fake_ssh.define_singleton_method(:execute) { |*| raise "must not ssh when derived url is known" }

    assert_equal "postgres://derived/db", DatabaseBackup.new(b).send(:resolve_database_url, fake_ssh)
  end

  # The universal fallback: an app with no derived URL AND no DATABASE_URL env
  # (older apps wired via database.yml) still reports its DSN through ActiveRecord.
  test "resolve_database_url asks the app via rails runner when there is no DATABASE_URL env" do
    app = @org.apps.create!(name: "k3", slug: "k3", deploy_method: "kamal", repository_url: "https://x/y.git")
    app.define_singleton_method(:derived_database_url) { |*| nil }
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "bk-backups", status: "pending", app: app)

    fake_ssh = Object.new
    fake_ssh.define_singleton_method(:execute) do |cmd|
      @last = cmd.include?("printenv") ? "" : "warn: noise\nCONDUCTOR_DSN=postgres://u:p@conductor-postgres:5432/appdb\n"
      true
    end
    fake_ssh.define_singleton_method(:output) { @last }

    url = DatabaseBackup.new(b).send(:resolve_database_url, fake_ssh)
    assert_equal "postgres://u:p@conductor-postgres:5432/appdb", url
  end

end
