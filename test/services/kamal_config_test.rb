require "test_helper"

class KamalConfigTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "kc@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/appone.git", branch: "main",
                             domain: "appone.example.com", port: 3000, ssl_enabled: true)
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "skb_raw_value", secret: true)
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://raw", secret: true)
    @app.env_variables.create!(key: "RAILS_MASTER_KEY", value: "deadbeef", secret: true)
    @app.env_variables.create!(key: "REDIS_URL", value: "redis://localhost", secret: false)
    @app.env_variables.create!(key: "KAMAL_REGISTRY_USERNAME", value: "nauman", secret: false)
    @app.env_variables.create!(key: "APP_HOST", value: "appone.example.com", secret: false)
  end

  def overlay = YAML.load(KamalConfig.new(@app).deploy_overlay_yaml)

  test "target_server overrides the overlay's destination host + ssh user (app transfer)" do
    target = @org.servers.create!(name: "box-b", status: "online", ip_address: "198.51.100.5",
                                  ssh_key: @key, ssh_user: "deploy2")
    yaml = YAML.load(KamalConfig.new(@app, target_server: target).deploy_overlay_yaml)

    assert_equal [ "198.51.100.5" ], yaml["servers"]["web"], "deploys to the target box, not the app's server"
    assert_equal "deploy2", yaml["ssh"]["user"]
    # Default (no target) still points at the app's own server.
    assert_equal [ "192.0.2.10" ], overlay["servers"]["web"]
  end

  test "overlay carries REAL literal coordinates — no placeholders, no ENV fallbacks" do
    yaml = KamalConfig.new(@app).deploy_overlay_yaml
    refute_match(/YOUR_SERVER_IP|your-user|\|\| /, yaml, "must not emit placeholder defaults")
    o = YAML.load(yaml)
    assert_equal "appone", o["service"]
    assert_equal [ "192.0.2.10" ], o["servers"]["web"]
    assert_equal "deploy", o["ssh"]["user"]
    assert_equal "appone.example.com", o["proxy"]["host"]
    assert_equal true, o["proxy"]["ssl"]
    assert_equal 3000, o["proxy"]["app_port"]
  end

  test "registry uses real username + a secret-list password reference" do
    o = overlay
    assert_equal "docker.io", o["registry"]["server"], "defaults to Kamal's default registry"
    assert_equal "nauman", o["registry"]["username"]
    assert_equal [ "KAMAL_REGISTRY_PASSWORD" ], o["registry"]["password"]
  end

  test "Caddy edge disables kamal-proxy and adds a loopback port plus healthcheck" do
    @server.update!(edge_type: "caddy")
    o = overlay

    assert_nil o["proxy"]
    assert_equal [ "192.0.2.10" ], o.dig("servers", "web", "hosts")
    assert_equal false, o.dig("servers", "web", "proxy")
    assert_equal "127.0.0.1:3000:3000", o.dig("servers", "web", "options", "publish")
    assert_match %r{curl -f http://127\.0\.0\.1:3000/up}, o.dig("servers", "web", "options", "health-cmd")
  end

  test "env is split: secrets listed, clear excludes deploy-coordinate keys" do
    env = overlay["env"]
    assert_equal %w[DATABASE_URL RAILS_MASTER_KEY SECRET_KEY_BASE], env["secret"].sort
    assert_includes env["clear"].keys, "REDIS_URL"
    refute_includes env["clear"].keys, "APP_HOST", "deploy-coordinate key must not leak into env.clear"
    refute_includes env["clear"].keys, "KAMAL_REGISTRY_USERNAME"
  end

  test "secrets file resolves from env (git-safe), documents the localvault seed, never raw values" do
    s = KamalConfig.new(@app).secrets_file
    # Resolution: variable substitution — Conductor injects at deploy, operator seeds once.
    assert_includes s, "SECRET_KEY_BASE=$SECRET_KEY_BASE"
    assert_includes s, "DATABASE_URL=$DATABASE_URL"
    assert_includes s, "KAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD"
    assert_includes s, "RAILS_MASTER_KEY=$(cat config/master.key)", "master key follows the Rails convention"
    # Header documents seeding the env ONCE from localvault (not every command).
    assert_includes s, "export SECRET_KEY_BASE=$(localvault get appone.SECRET_KEY_BASE --vault devops)"
    # Never raw secret values.
    refute_match(/skb_raw_value|postgres:\/\/raw|deadbeef/, s)
  end

  test "vault is configurable in the seed header" do
    s = KamalConfig.new(@app, vault: "production").secrets_file
    assert_includes s, "--vault production"
    refute_includes s, "--vault devops"
  end

  test "files returns the two destination artifacts" do
    files = KamalConfig.new(@app).files
    assert_equal %w[.kamal/secrets.production config/deploy.production.yml], files.keys.sort
  end
end
