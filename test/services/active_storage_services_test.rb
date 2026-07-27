require "test_helper"

# A RemoteRailsRunner stub that returns a canned Result.
class FakeRunner
  def initialize(output:, ok: true) = (@output = output; @ok = ok)
  def run(_script) = RemoteRailsRunner::Result.new(ok: @ok, output: @output, exit_code: @ok ? 0 : 3)
end

class ActiveStorageAuditorTest < ActiveSupport::TestCase
  setup { @app = App.new(name: "A", slug: "a", deploy_method: "kamal") }

  test "parses the audit payload" do
    payload = { "total_blobs" => 1512, "service_distribution" => { "local" => 514, "cloudflare_r2" => 998 },
                "configured_service" => "cloudflare_r2", "storage_reachable" => true, "blobs_not_on_configured_service" => 514 }
    runner = FakeRunner.new(output: RemoteRailsRunner::MARKER + payload.to_json)
    r = ActiveStorageAuditor.new(@app, runner: runner).call
    assert r.ok?
    assert_equal 514, r.data["blobs_not_on_configured_service"]
    assert_equal "cloudflare_r2", r.data["configured_service"]
  end

  test "reports a clear error when no container is found" do
    runner = FakeRunner.new(output: "NO_CONTAINER (service: a)", ok: false)
    r = ActiveStorageAuditor.new(@app, runner: runner).call
    refute r.ok?
    assert_match(/No running container/, r.error)
  end

  test "the audit script is literal (no build-time interpolation leaked) and carries the marker" do
    s = ActiveStorageAuditor.new(@app, runner: FakeRunner.new(output: "")).script
    assert_includes s, RemoteRailsRunner::MARKER
    refute_includes s, "__MARKER__"
    assert_includes s, "ActiveStorage::Blob.group(:service_name).count"
  end
end

class ActiveStorageR2MigratorTest < ActiveSupport::TestCase
  setup { @app = App.new(name: "A", slug: "a", deploy_method: "kamal") }

  test "substitutes from/to/limit/marker into the script" do
    s = ActiveStorageR2Migrator.new(@app, runner: FakeRunner.new(output: "")).script(from: "local", to: "cloudflare_r2", limit: 50)
    assert_includes s, 'from = "local"'
    assert_includes s, 'to = "cloudflare_r2"'
    assert_includes s, "limit = 50"
    assert_includes s, RemoteRailsRunner::MARKER
    refute_includes s, "__FROM__"
    refute_includes s, "__LIMIT__"
  end

  test "parses the migration counts payload" do
    payload = { "from" => "local", "to" => "cloudflare_r2", "migrated" => 998, "missing_source" => 514, "errors" => 0, "remaining_migratable" => 0 }
    runner = FakeRunner.new(output: RemoteRailsRunner::MARKER + payload.to_json)
    r = ActiveStorageR2Migrator.new(@app, runner: runner).call
    assert r.ok?
    assert_equal 998, r.data["migrated"]
    assert_equal 0, r.data["remaining_migratable"]
  end

  test "refuses an unsafe service name (script injection guard)" do
    r = ActiveStorageR2Migrator.new(@app, runner: FakeRunner.new(output: "")).call(from: "local; rm -rf /", to: "cloudflare_r2")
    refute r.ok?
    assert_match(/Invalid service name/, r.error)
  end
end

class R2StorageConfigTest < ActiveSupport::TestCase
  test "generates the storage.yml block, production line, and env keys" do
    h = R2StorageConfig.new(bucket: "platepose", account_id: "acc123").to_h
    assert_includes h[:storage_yml_append], "service: S3"
    assert_includes h[:storage_yml_append], 'ENV.fetch("R2_BUCKET", "platepose")'
    assert_includes h[:storage_yml_append], "r2.cloudflarestorage.com"
    assert_equal "config.active_storage.service = :cloudflare_r2", h[:production_rb_line]
    assert_equal R2StorageConfig::ENV_KEYS, h[:required_env]
    assert h[:account_id_set]
  end
end
