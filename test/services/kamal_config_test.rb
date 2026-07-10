require "test_helper"

class KamalConfigTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "kc@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "135.181.114.59",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git", branch: "main",
                             domain: "kuickr.co", port: 3000, ssl_enabled: true)
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "skb_raw_value", secret: true)
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://raw", secret: true)
    @app.env_variables.create!(key: "RAILS_MASTER_KEY", value: "deadbeef", secret: true)
    @app.env_variables.create!(key: "REDIS_URL", value: "redis://localhost", secret: false)
    @app.env_variables.create!(key: "KAMAL_REGISTRY_USERNAME", value: "nauman", secret: false)
    @app.env_variables.create!(key: "APP_HOST", value: "kuickr.co", secret: false)
  end

  def overlay = YAML.load(KamalConfig.new(@app).deploy_overlay_yaml)

  test "overlay carries REAL literal coordinates — no placeholders, no ENV fallbacks" do
    yaml = KamalConfig.new(@app).deploy_overlay_yaml
    refute_match(/YOUR_SERVER_IP|your-user|\|\| /, yaml, "must not emit placeholder defaults")
    o = YAML.load(yaml)
    assert_equal "kuickr", o["service"]
    assert_equal ["135.181.114.59"], o["servers"]["web"]
    assert_equal "deploy", o["ssh"]["user"]
    assert_equal "kuickr.co", o["proxy"]["host"]
    assert_equal true, o["proxy"]["ssl"]
    assert_equal 3000, o["proxy"]["app_port"]
  end

  test "registry uses real username + a secret-list password reference" do
    o = overlay
    assert_equal "docker.io", o["registry"]["server"], "defaults to Kamal's default registry"
    assert_equal "nauman", o["registry"]["username"]
    assert_equal ["KAMAL_REGISTRY_PASSWORD"], o["registry"]["password"]
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
    assert_includes s, "export SECRET_KEY_BASE=$(localvault get kuickr.SECRET_KEY_BASE --vault devops)"
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
