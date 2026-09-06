require "test_helper"

# The rule only pays off if the raw file stops being written. Today a
# self-describing app gets BOTH: `.kamal/secrets` with raw values (written
# unconditionally) and `.kamal/secrets.production` with pointers. Kamal prefers the
# destination file when deploying with `-d production`, so the raw one is written
# for nothing — a plaintext credential file on disk that no deploy even reads.
class KamalSecretsTransportTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "kst@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.121")
    @app = @org.apps.create!(name: "appone", slug: "appone", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
    @app.env_variables.create!(key: "API_TOKEN", value: "s3cr3t-value", secret: true)
    @dir = Dir.mktmpdir
  end

  teardown { FileUtils.remove_entry(@dir) if @dir && File.exist?(@dir) }

  def deployer
    d = KamalDeployer.new(@app, @app.deployments.create!(user: @org.users.first, status: "deploying"))
    d.define_singleton_method(:checkout_dir) { @checkout_dir_override }
    d.instance_variable_set(:@checkout_dir_override, @dir)
    d
  end

  test "a self-describing app gets pointers and no raw-value file" do
    d = deployer
    d.send(:write_secrets_file)
    d.send(:write_self_describing_config)

    raw = File.join(@dir, ".kamal", "secrets")
    assert_not File.exist?(raw), "the raw-value file must not be written at all"

    pointers = File.read(File.join(@dir, ".kamal", "secrets.#{KamalConfig::DESTINATION}"))
    assert_match(/API_TOKEN=\$API_TOKEN/, pointers)
    assert_no_match(/s3cr3t-value/, pointers, "the pointer file must never carry a value")
  end

  # NOT WRITING IT IS NOT THE SAME AS REMOVING IT. A checkout that predates the rule
  # already holds .kamal/secrets with raw values, and `git reset --hard` preserves an
  # untracked file — so an app reported compliant kept its old plaintext credentials
  # on disk. The first version of this test started from an empty directory and so
  # could not have caught it.
  test "an existing raw-value file is removed, not merely left unwritten" do
    FileUtils.mkdir_p(File.join(@dir, ".kamal"))
    stale = File.join(@dir, ".kamal", "secrets")
    File.write(stale, "API_TOKEN=s3cr3t-value\n")

    deployer.send(:write_secrets_file)

    assert_not File.exist?(stale), "a stale plaintext secrets file must be deleted"
  end

  # A REPO MAY COMMIT ITS OWN .kamal/secrets — Conductor's does, holding pointers
  # rather than values. Deleting a tracked file is editing someone else's repository,
  # not clearing our residue, and the first version of this cleanup did exactly that.
  test "a committed secrets file is left alone" do
    FileUtils.mkdir_p(File.join(@dir, ".kamal"))
    committed = File.join(@dir, ".kamal", "secrets")
    File.write(committed, "RAILS_MASTER_KEY=$(cat config/master.key)\n")

    d = deployer
    d.instance_variable_set(:@shell, TrackedShell.new)
    d.send(:write_secrets_file)

    assert File.exist?(committed), "a file the repo committed is not ours to delete"
  end

  class TrackedShell
    def run(*, **) = Struct.new(:success?).new(true)
  end

  # Grandfathered apps still need their secrets, so the raw path stays for them —
  # and that is exactly what the audit exists to make visible and finite.
  test "a grandfathered app still gets its secrets file" do
    @app.update_columns(self_describing: false)
    deployer.send(:write_secrets_file)

    assert File.exist?(File.join(@dir, ".kamal", "secrets"))
  end
end
