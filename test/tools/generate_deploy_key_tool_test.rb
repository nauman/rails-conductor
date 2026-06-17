require "test_helper"

class GenerateDeployKeyToolTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "gdk@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git")
  end

  test "generates a deploy key and returns the public key + GitHub link" do
    res = GenerateDeployKeyTool.new(user: @user).call("app_name" => "Kuickr")

    assert res.success?, res.error
    assert_match(/\Assh-ed25519 /, res.value[:public_key])
    assert_equal "https://github.com/pavelabs/kuickr/settings/keys/new", res.value[:add_to]
    assert_equal @org, res.value[:_organization]
    assert @app.reload.deploy_key.present?
  end

  test "fails cleanly for an unknown app" do
    res = GenerateDeployKeyTool.new(user: @user).call("app_name" => "Nope")
    refute res.success?
    assert_includes res.error, "App not found"
  end
end
