require "test_helper"

class CloudflareToolsTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "cf-tools@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "edge", status: "online", ip_address: "10.0.0.7", ssh_key: key)
    @app = @org.apps.create!(name: "Calm", slug: "calm", server: @server, deploy_method: "docker", status: "running", domain: "calm.page")
    @cred = @org.credentials.create!(
      name: "InventList", provider: "cloudflare", api_key: "cf-token",
      account_id: "a1", verified_at: Time.current,
      zones: [ { "id" => "z1", "name" => "calm.page", "account_id" => "a1" } ].to_json
    )
  end

  test "conductor_read action=cloudflare surfaces accounts, zones, read-only attach cmds, proxyable apps" do
    res = ConductorReadTool.new(user: @user).call("action" => "cloudflare")
    assert res.success?, res.error
    v = res.value

    acct = v[:connected_accounts].find { |a| a[:name] == "InventList" }
    assert acct, "connected account missing"
    assert acct[:verified]
    assert_includes acct[:zones], "calm.page"
    # Only the curated read-only servers are offered — never the broad aggregate.
    assert_equal Credential::CLOUDFLARE_MCP_SERVERS.size, acct[:read_only_mcp_attach].size
    refute acct[:read_only_mcp_attach].any? { |c| c.include?("https://mcp.cloudflare.com/mcp") }

    proxyable = v[:proxyable_apps].find { |p| p[:app] == "Calm" }
    assert proxyable, "proxyable app not detected"
    assert_equal "calm.page", proxyable[:domain]
    assert_equal "InventList", proxyable[:account]
  end

  test "conductor_domain action=put_behind_cloudflare proxies the app domain via CloudflareCutover" do
    fake = Struct.new(:m) do
      def put_behind!(ssl_mode:) = CloudflareCutover::Result.new(ok: true, message: "#{ssl_mode}: done")
    end.new(nil)

    CloudflareCutover.stub(:new, ->(_app) { fake }) do
      res = ConductorDomainTool.new(user: @user).call("action" => "put_behind_cloudflare", "app_name" => "Calm")
      assert res.success?, res.error
      assert_equal "calm.page", res.value[:domain]
      assert_equal "full", res.value[:ssl_mode]
      assert_equal @org, res.value[:_organization]
    end
  end

  test "put_behind_cloudflare reports the cutover failure message" do
    fake = Struct.new(:m) do
      def put_behind!(ssl_mode:) = CloudflareCutover::Result.new(ok: false, message: "No connected Cloudflare account owns calm.page.")
    end.new(nil)

    CloudflareCutover.stub(:new, ->(_app) { fake }) do
      res = ConductorDomainTool.new(user: @user).call("action" => "put_behind_cloudflare", "app_id" => @app.id)
      refute res.success?
      assert_includes res.error, "No connected Cloudflare account"
    end
  end
end
