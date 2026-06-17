require "test_helper"

class KamalEnvWriterTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "kew@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal")
  end

  test "renders dotenv KEY=value lines sorted by key" do
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "abc123")
    @app.env_variables.create!(key: "DATABASE_URL", value: "postgres://u:p@h/db")

    content = KamalEnvWriter.secrets_content(@app)

    # sorted: DATABASE_URL before SECRET_KEY_BASE
    assert_equal "DATABASE_URL=postgres://u:p@h/db\nSECRET_KEY_BASE=abc123\n", content
    assert_equal %w[DATABASE_URL SECRET_KEY_BASE], KamalEnvWriter.managed_keys(@app)
  end

  test "empty when the app has no env vars" do
    assert_equal "\n", KamalEnvWriter.secrets_content(@app)
    assert_empty KamalEnvWriter.managed_keys(@app)
  end
end
