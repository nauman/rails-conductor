require "test_helper"

class EnvVariableTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ev@example.com")
    org = Organization.create_for(user, name: "Acme")
    server = org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = org.apps.create!(name: "App", slug: "app", server: server, deploy_method: "docker",
                            repository_url: "https://github.com/x/y.git")
  end

  test "to_docker_env_redacted masks a secret value but not the key" do
    ev = @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "supersecret", secret: true)
    assert_equal "-e SECRET_KEY_BASE=[REDACTED]", ev.to_docker_env_redacted
    refute_includes ev.to_docker_env_redacted, "supersecret"
    assert_includes ev.to_docker_env, "supersecret", "the real command still carries the value"
  end

  test "to_docker_env_redacted shows non-secret values" do
    ev = @app.env_variables.create!(key: "RAILS_ENV", value: "production", secret: false)
    assert_equal "-e RAILS_ENV=production", ev.to_docker_env_redacted
  end
end
