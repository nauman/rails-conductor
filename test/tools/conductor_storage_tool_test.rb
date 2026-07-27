require "test_helper"

class ConductorStorageToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "storage-tools@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "edge", status: "online", ip_address: "10.0.0.7", ssh_key: key)
    @app = @org.apps.create!(name: "Stored", slug: "stored", server: @server, deploy_method: "kamal", status: "running")
  end

  test "action=audit returns the parsed audit via ActiveStorageAuditor" do
    fake = Struct.new(:x) do
      def call = ActiveStorageAuditor::Result.new(ok: true, data: { "total_blobs" => 10, "configured_service" => "cloudflare_r2", "blobs_not_on_configured_service" => 2 })
    end.new(nil)

    ActiveStorageAuditor.stub(:new, ->(*, **) { fake }) do
      res = ConductorStorageTool.new(user: @user).call("action" => "audit", "app_name" => "Stored")
      assert res.success?, res.error
      assert_equal 10, res.value["total_blobs"]
      assert_equal "Stored", res.value[:app]
      assert_equal @org, res.value[:_organization]
    end
  end

  test "action=configure generates the R2 config (no stubbing, pure)" do
    res = ConductorStorageTool.new(user: @user).call("action" => "configure", "app_id" => @app.id, "bucket" => "stored-bucket", "account_id" => "acc9")
    assert res.success?, res.error
    assert_includes res.value[:storage_yml_append], "service: S3"
    assert_includes res.value[:required_env], "R2_ACCESS_KEY_ID"
    assert_equal "stored-bucket", res.value[:bucket]
  end

  test "action=configure requires a bucket" do
    res = ConductorStorageTool.new(user: @user).call("action" => "configure", "app_id" => @app.id)
    refute res.success?
    assert_includes res.error, "bucket"
  end

  test "action=migrate returns the counts via ActiveStorageR2Migrator" do
    fake = Struct.new(:x) do
      def call(**) = ActiveStorageR2Migrator::Result.new(ok: true, data: { "migrated" => 998, "remaining_migratable" => 0, "missing_source" => 514 })
    end.new(nil)

    ActiveStorageR2Migrator.stub(:new, ->(*, **) { fake }) do
      res = ConductorStorageTool.new(user: @user).call("action" => "migrate", "app_name" => "Stored")
      assert res.success?, res.error
      assert_equal 998, res.value["migrated"]
      assert_equal 0, res.value["remaining_migratable"]
    end
  end

  test "audit refuses an app with no container capability (native/no SSH)" do
    native = @org.apps.create!(name: "Nat", slug: "nat", server: @server, deploy_method: "native", status: "running")
    res = ConductorStorageTool.new(user: @user).call("action" => "audit", "app_id" => native.id)
    refute res.success?
    assert_match(/Kamal or Docker/, res.error)
  end

  test "unknown app is reported" do
    res = ConductorStorageTool.new(user: @user).call("action" => "audit", "app_name" => "Ghost")
    refute res.success?
    assert_includes res.error, "App not found"
  end

  test "action=set_cors defaults origins to the app domain + wildcard and delegates" do
    @app.update!(domain: "calm.page")
    captured = {}
    fake = Struct.new(:x) do
      define_method(:set_cors) do |bucket, account_domain:, origins:|
        captured.merge!(bucket: bucket, account_domain: account_domain, origins: origins)
        CloudflareR2Admin::Result.new(ok: true, message: "CORS set on #{bucket}.", data: { bucket: bucket, origins: origins })
      end
    end.new(nil)

    CloudflareR2Admin.stub(:new, ->(*, **) { fake }) do
      res = ConductorStorageTool.new(user: @user).call("action" => "set_cors", "app_id" => @app.id, "bucket" => "calm-page-storage")
      assert res.success?, res.error
      assert_equal "calm-page-storage", captured[:bucket]
      assert_equal "calm.page", captured[:account_domain]
      assert_equal [ "https://calm.page", "https://*.calm.page" ], captured[:origins]
      assert_equal @org, res.value[:_organization]
    end
  end

  test "action=set_cors requires a bucket" do
    @app.update!(domain: "calm.page")
    res = ConductorStorageTool.new(user: @user).call("action" => "set_cors", "app_id" => @app.id)
    refute res.success?
    assert_includes res.error, "bucket"
  end

  test "action=connect_domain delegates the bucket + domain" do
    captured = {}
    fake = Struct.new(:x) do
      define_method(:connect_domain) do |bucket, domain|
        captured.merge!(bucket: bucket, domain: domain)
        CloudflareR2Admin::Result.new(ok: true, message: "#{domain} connected.", data: { bucket: bucket, domain: domain })
      end
    end.new(nil)

    CloudflareR2Admin.stub(:new, ->(*, **) { fake }) do
      res = ConductorStorageTool.new(user: @user).call(
        "action" => "connect_domain", "app_id" => @app.id, "bucket" => "calm-page-storage", "domain" => "assets.calm.page"
      )
      assert res.success?, res.error
      assert_equal "calm-page-storage", captured[:bucket]
      assert_equal "assets.calm.page", captured[:domain]
    end
  end

  test "action=connect_domain requires a domain" do
    res = ConductorStorageTool.new(user: @user).call("action" => "connect_domain", "app_id" => @app.id, "bucket" => "b")
    refute res.success?
    assert_includes res.error, "domain"
  end
end
