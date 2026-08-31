require "test_helper"

# Conductor stored a live OAuth client secret in plaintext in a deployment log,
# because the app declared it under kamal's `env: clear:` instead of `env: secret:`
# — so kamal inlined the value into the `docker run` command line and
# KamalDeployer captured that verbatim.
#
# The lesson is not "that app misconfigured itself". It is that **the control plane
# trusted an app's own declaration about what is secret**. AppDeployer already
# redacted using Conductor's record; the kamal path had no redaction at all, and
# either way a record-driven check cannot catch a key the record does not know is
# secret.
#
# So this scrubs on TWO independent grounds, and the second is the one that matters:
# what Conductor knows is secret, and what merely LOOKS secret by name.
class SecretScrubberTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "scrub@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.8")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def scrub(line) = SecretScrubber.new(@app).scrub(line)

  # THE EXACT SHAPE THAT LEAKED.
  test "redacts a secret-looking env value the app declared as clear" do
    out = scrub(%(docker run -d --env GOOGLE_CLIENT_SECRET="abc123-live-value" --env RAILS_ENV="production" img))

    assert_not_includes out, "abc123-live-value"
    assert_includes out, "GOOGLE_CLIENT_SECRET=[REDACTED]"
    assert_includes out, %(RAILS_ENV="production"), "non-secret config must stay readable"
  end

  test "redacts unquoted values and the short -e form" do
    out = scrub("docker run -e API_TOKEN=t0psecret --env DB_PASSWORD=hunter2 img")

    assert_not_includes out, "t0psecret"
    assert_not_includes out, "hunter2"
  end

  test "covers the whole family of secret-ish names" do
    %w[FOO_SECRET FOO_TOKEN FOO_PASSWORD FOO_API_KEY FOO_CREDENTIALS FOO_PRIVATE_KEY DATABASE_URL SENTRY_DSN].each do |key|
      out = scrub("--env #{key}=leakvalue")
      assert_not_includes out, "leakvalue", "#{key} should have been redacted"
    end
  end

  # A key Conductor KNOWS is secret gets redacted even when its name looks benign.
  test "redacts a key Conductor records as secret regardless of its name" do
    @app.stub(:deploy_secret_keys, [ "HARMLESS_LOOKING" ]) do
      out = SecretScrubber.new(@app).scrub("--env HARMLESS_LOOKING=leakvalue --env OTHER=fine")

      assert_not_includes out, "leakvalue"
      assert_includes out, "OTHER=fine"
    end
  end

  # Over-redacting a log makes it useless and trains people to bypass the scrubber.
  test "leaves ordinary configuration alone" do
    line = %(--env RAILS_ENV="production" --env WEB_CONCURRENCY="2" --env APP_HOST="shop.test")

    assert_equal line, scrub(line)
  end

  # kamal passes true secrets bare (value comes from the uploaded env file). A bare
  # flag has nothing to redact and must not be mangled into something unreadable.
  test "a bare --env flag with no value is untouched" do
    assert_equal "--env STRIPE_SECRET_KEY --env FOO=1", scrub("--env STRIPE_SECRET_KEY --env FOO=1")
  end

  test "nil and empty input are safe" do
    assert_nil SecretScrubber.new(@app).scrub(nil)
    assert_equal "", scrub("")
  end
end
