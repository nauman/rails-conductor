require "test_helper"

# ADR 0003 says there is one deploy path and Kamal is the contract. A kamal app
# that is not self-describing does not honour that contract: Conductor writes
# `.kamal/secrets` with RAW VALUES instead of the generated overlay plus git-safe
# pointers, so "sensitive" buys nothing on the one path where it could mean
# something.
#
# Compulsory for new apps; existing ones are grandfathered and reported, because
# flipping eight live apps' generated config at once is a change nobody is watching.
class KamalIsSelfDescribingTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ksd@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.120")
  end

  def build_app(**overrides)
    @org.apps.new({ name: "appone", slug: "appone", server: @server, deploy_method: "kamal",
                    port: 3000, repository_url: "https://github.com/x/y.git" }.merge(overrides))
  end

  # The caller should not have to know the rule — it should be impossible to get
  # wrong, not merely refused.
  test "a new kamal app is self-describing without anyone asking for it" do
    app = build_app
    assert app.save, app.errors.full_messages.join(", ")

    assert app.self_describing?
  end

  # A new kamal app is COERCED rather than refused. The column defaults to false, so
  # "the caller said false" and "the caller said nothing" are indistinguishable — and
  # refusing both would make every existing creation path fail until each one was
  # taught the rule. Coercing on the way in and refusing to go backwards gets the
  # same guarantee without a flag day.
  test "asking for a non-self-describing kamal app gets a self-describing one" do
    app = build_app(self_describing: false)

    assert app.save, app.errors.full_messages.join(", ")
    assert app.self_describing?
  end

  test "an existing kamal app cannot be turned back" do
    app = build_app
    app.save!

    app.self_describing = false

    assert_not app.valid?
  end

  # Switching an app TO kamal adopts the contract with it.
  test "changing deploy method to kamal adopts the contract" do
    app = build_app(deploy_method: "docker", self_describing: false)
    app.save!

    app.update!(deploy_method: "kamal")

    assert app.reload.self_describing?
  end

  # Non-kamal apps have no kamal artifact, so the rule does not apply to them.
  test "a docker app is unaffected" do
    app = build_app(deploy_method: "docker", self_describing: false)

    assert app.save, app.errors.full_messages.join(", ")
    assert_not app.self_describing?
  end

  # Grandfathered: a row that predates the rule stays valid, so nothing breaks for
  # an app nobody has migrated yet.
  test "an existing non-compliant app stays usable" do
    app = build_app
    app.save!
    app.update_columns(self_describing: false)

    app.reload.update!(notes: "still editable")

    assert_equal "still editable", app.reload.notes
  end
end
