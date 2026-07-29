require "test_helper"

# conductor_app action=convert_database — the invocable ignition for
# SharedToDedicatedConverter. The converter's own behaviour is covered in
# shared_to_dedicated_converter_test; here we test the TOOL: gating, app scoping,
# object-store resolution, and that it delegates to the converter.
class ConvertDatabaseToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "conv-tool@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git",
                             database_mode: "shared", database_placement: "colocated")
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://shared/appone")
    @cred = @org.credentials.create!(name: "r2", provider: "aws", api_key: "k", api_secret: "s", account_id: "a1")
  end

  def run_tool(**over)
    ConductorAppTool.new(user: @user).call({ "action" => "convert_database", "app_name" => "Appone" }.merge(over))
  end

  # A fake converter that records how it was called and returns a canned Result.
  def stub_converter(ok:, message: "done", &block)
    fake = Object.new
    data = { next: "deploy appone", rollback_dsn_key: "DATABASE_URL_PRE_CONVERT" }
    result = SharedToDedicatedConverter::Result.new(ok: ok, message: message, data: data)
    captured = {}
    fake.define_singleton_method(:call) { |**kw| captured.merge!(kw); result }
    SharedToDedicatedConverter.stub(:new, ->(_app) { fake }) { block.call(captured) }
  end

  test "a bare call previews and mutates nothing" do
    res = run_tool
    assert res.success?, res.error
    assert_equal false, res.value[:action_taken]
    assert_equal "confirmation_required", res.value[:status]
    assert_equal "shared", @app.reload.database_mode
  end

  test "confirm delegates to the converter and reports converted" do
    captured = nil
    stub_converter(ok: true, message: "appone converted") do |cap|
      res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "appone-db-transfer")
      assert res.success?, res.error
      assert_equal "converted", res.value[:status]
      assert_equal "appone converted", res.value[:message]
      captured = cap
    end
    assert_equal @cred, captured[:credential]
    assert_equal "appone-db-transfer", captured[:bucket]
    assert_equal "cloudflare_r2", captured[:provider]
  end

  test "a converter failure surfaces as a tool failure" do
    stub_converter(ok: false, message: "already dedicated") do |_cap|
      res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "b")
      refute res.success?
      assert_match(/already dedicated/, res.error)
    end
  end

  test "confirm without a credential or R2 env is refused (no DB copy possible)" do
    res = run_tool("confirm" => true)
    refute res.success?
    assert_match(/object store/, res.error)
  end

  test "confirm without credential_id derives the object store from the app's own R2 env" do
    @app.env_variables.create!(key: "R2_ACCESS_KEY_ID", value: "AKID")
    @app.env_variables.create!(key: "R2_SECRET_ACCESS_KEY", value: "SEKRET")
    @app.env_variables.create!(key: "R2_ENDPOINT", value: "https://acct123.r2.cloudflarestorage.com")
    captured = nil
    stub_converter(ok: true) do |cap|
      res = run_tool("confirm" => true) # no credential_id / bucket
      assert res.success?, res.error
      captured = cap
    end
    derived = @org.credentials.find_by(provider: "aws", name: "appone R2 (auto DB transfer)")
    assert derived, "derived a managed credential from the app's own R2 env"
    assert_equal "acct123", derived.account_id
    assert_equal derived, captured[:credential]
    assert_equal "appone-db-transfer", captured[:bucket]
  end

  test "an unknown provider is refused" do
    res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "b", "provider" => "not-a-vendor")
    refute res.success?
    assert_match(/provider/, res.error)
  end

  test "an unknown app is not found" do
    res = ConductorAppTool.new(user: @user).call("action" => "convert_database", "app_name" => "Nope")
    refute res.success?
    assert_match(/not found/, res.error)
  end
end
