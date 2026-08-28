require "test_helper"

# An externally-driven app keeps deploy_method "kamal" — the ARTIFACT contract is
# still kamal, and FleetCanon exists precisely so that fact can stay true while a
# different driver performs the roll. KamalOps was asking the artifact question
# (`app.kamal?`) to decide a DRIVER question, so it attempted kamal against a
# repo whose config deliberately points nowhere, waited out a DNS failure, and
# reported that instead of the thing an operator needed to know.
class KamalOpsExternalDriverTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ko@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.5")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def external!
    @app.update!(deploy_hold: true,
                 deploy_hold_reason: "MIGRATED: deploys use repo bin/deploy-ssdnode. Do NOT kamal deploy.")
  end

  test "an externally-driven app says so, instead of failing against its config" do
    external!
    assert_equal "external", FleetCanon.shape_for(@app)[:driver], "precondition: the canon sees the driver"

    reason = KamalOps.new(@app).unavailable_reason

    assert reason, "kamal must not be attempted for an app it does not drive"
    assert_match(/does not deploy/i, reason)
    assert_match(/bin\/deploy-ssdnode/, reason,
                 "name the path that DOES deploy it — the operator's next question")
  end

  # The artifact contract is untouched: this is still a kamal-built image, and
  # saying otherwise is the conflation FleetCanon was written to end.
  test "the app keeps deploy_method kamal — only the driver differs" do
    external!

    assert @app.kamal?, "an external driver does not change how the image is built"
  end

  test "a Conductor-driven kamal app is unaffected" do
    assert_equal "conductor", FleetCanon.shape_for(@app)[:driver]

    reason = KamalOps.new(@app).unavailable_reason

    assert_nil reason.to_s[/does not deploy via kamal/], "must still use kamal where kamal drives"
  end
end
