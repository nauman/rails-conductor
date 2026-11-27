require "test_helper"

# The gate that would have stopped a public image from shipping. It is OPT-IN:
# the preflight also renders on an app page, and that render must stay a pure
# read, so only the deploy path hands it a prober.
class DeployPreflightImageVisibilityTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "pfv@example.com")
    @org = Organization.create_for(user, name: "PFV")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.40",
                                   ssh_key: @key, ssh_user: "deploy",
                                   last_audit_status: "secure", last_audit_at: Time.current)
    @app = @org.apps.create!(name: "Vis", server: @server, status: "stopped",
                             deploy_method: "kamal", repository_url: "https://github.com/x/y")
    @app.seed_applications.create!(status: "succeeded", applied_at: Time.current)
    # Already shipped once, so "not readable" is a statement about a repository
    # that EXISTS. A never-deployed app is covered on its own below.
    @app.update!(deployed_at: 1.day.ago)
  end

  # Stands in for RegistryVisibility, returning its real Result so the preflight
  # is tested against the shape it actually receives.
  def prober(status, detail: "stub", repository: "anorg/vis", registry: "docker.io")
    Struct.new(:result) do
      def check = result
    end.new(RegistryVisibility::Result.new(status: status, registry: registry,
                                           repository: repository, detail: detail))
  end

  def row(app: @app, visibility: nil)
    DeployPreflight.new(app, visibility: visibility).check
  end

  def visibility_row(result) = result.checks.find { |c| c.key == :image_visibility }

  test "a publicly readable image repository fails and blocks the deploy" do
    result = row(visibility: prober(:public, repository: "anorg/vis", detail: "anyone can list it"))

    assert_equal :fail, visibility_row(result).status
    assert result.blocked?, "a published image must stop the deploy"
    assert_includes visibility_row(result).detail, "anorg/vis"
  end

  test "an image repository that is not publicly readable is ok and does not block" do
    result = row(visibility: prober(:not_public))

    assert_equal :ok, visibility_row(result).status
    refute result.blocked?
  end

  # An unreachable registry must not stop deploys. The only override is Force,
  # which bypasses EVERY other gate — so a flaky probe that blocks would make
  # people routinely skip the audit and seed gates too.
  test "an unknown visibility warns and never blocks" do
    result = row(visibility: prober(:unknown, detail: "registry unreachable"))

    assert_equal :warn, visibility_row(result).status
    refute result.blocked?
    assert_includes visibility_row(result).detail, "unreachable"
  end

  # The page render path: no prober, no network, and no free green either.
  test "without a prober the row is skipped rather than reported as safe" do
    result = row(visibility: nil)

    assert_equal :skip, visibility_row(result).status
    refute result.blocked?
  end

  test "a native app has no image to publish" do
    native = @org.apps.create!(name: "Native", server: @server, status: "stopped",
                               deploy_method: "native", repository_url: "https://github.com/x/z")
    native.seed_applications.create!(status: "succeeded", applied_at: Time.current)

    result = row(app: native, visibility: prober(:public))

    assert_equal :skip, visibility_row(result).status
    refute result.blocked?, "a native app ships no image, so this gate cannot apply"
  end

  # Found by auditing this gate: without an opt-out, an intentionally public image
  # is blocked on every deploy and the only escape is Force, which also turns off
  # the audit and seed gates. The declaration must not buy silence, though.
  test "a deliberately public image warns instead of blocking" do
    @app.env_variables.create!(key: DeployPreflight::PUBLIC_ACK, value: "true")

    result = row(visibility: prober(:public))

    assert_equal :warn, visibility_row(result).status
    refute result.blocked?
    assert_includes visibility_row(result).detail, DeployPreflight::PUBLIC_ACK
  end

  test "only an explicit affirmative declares a public image deliberate" do
    [ "false", "no", "0", "", "maybe" ].each do |value|
      @app.env_variables.find_or_create_by!(key: DeployPreflight::PUBLIC_ACK).update!(value: value)

      result = row(visibility: prober(:public))

      assert_equal :fail, visibility_row(result).status, "#{value.inspect} must not clear the gate"
      assert result.blocked?
    end
  end

  # Also found by auditing: anonymously, "private" and "does not exist" are the
  # same answer, and before the first push there is nothing to read. The registry
  # creates the repository on that push — public, in a personal namespace.
  test "a never-deployed app cannot be cleared, because the repository does not exist yet" do
    @app.update!(deployed_at: nil, container_id: nil)

    result = row(visibility: prober(:not_public))

    assert_equal :warn, visibility_row(result).status
    refute result.blocked?
    assert_match(/never deployed|empty repository/i, visibility_row(result).detail)
  end

  test "a public image on a never-deployed app still blocks" do
    @app.update!(deployed_at: nil, container_id: nil)

    result = row(visibility: prober(:public))

    assert_equal :fail, visibility_row(result).status
    assert result.blocked?
  end

  test "the deploy path probes visibility for real, so the gate has live evidence" do
    probed = false
    fake = Object.new
    fake.define_singleton_method(:check) do
      probed = true
      RegistryVisibility::Result.new(status: :not_public, registry: "docker.io",
                                     repository: "anorg/vis", detail: "refused")
    end

    RegistryVisibility.stub(:new, ->(_app) { fake }) do
      @app.start_deployment!(commit_sha: "abc1234")
    end

    assert probed, "App#start_deployment! must ask the registry what the world can see"
  end
end
