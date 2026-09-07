require "test_helper"

# Two migrations are outstanding across the fleet — apps that predate the kamal
# contract and apps with no chosen build venue. Both were deliberately left as
# per-app decisions rather than a bulk flip, which means the reminder has to arrive
# where the decision is made: at the deploy, on that app.
#
# A list somewhere else is a list nobody reads.
class ContractNagTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cn@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.140")
    @subject = @org.apps.create!(name: "appone", slug: "appone", server: @server, deploy_method: "kamal",
                                 port: 3000, repository_url: "https://github.com/x/y.git")
  end

  def rows = DeployPreflight.new(@subject.reload).check.checks

  def row(key) = rows.find { |c| c[:key] == key }

  test "a compliant app is not nagged" do
    assert_equal :ok, row(:contract)[:status]
  end

  # WARN, never block. These apps deploy correctly today; the point is that each
  # deploy is the moment someone can decide, not that deploys should stop.
  test "an app predating the kamal contract is flagged at its own deploy" do
    @subject.update_columns(self_describing: false)

    contract = row(:contract)

    assert_equal :warn, contract[:status]
    assert_match(/raw secret values/i, contract[:detail])
    assert_match(/migrate-to-self-describing/, contract[:detail], "must cite the ritual that resolves it")
  end

  test "an app with no chosen build venue is flagged" do
    @subject.update_columns(build_venue: nil)

    venue = row(:venue)

    assert_equal :warn, venue[:status]
    assert_match(/has not chosen/i, venue[:detail])
  end

  test "a chosen venue is not flagged" do
    @subject.update!(build_venue: "control")

    assert_equal :ok, row(:venue)[:status]
  end

  # A docker or native app has no kamal contract to adopt, so nagging it would be
  # noise that trains people to read past the warnings that mean something.
  test "a non-kamal app is not nagged about the kamal contract" do
    @subject.update!(deploy_method: "docker")

    assert_equal :skip, row(:contract)[:status]
  end
end
