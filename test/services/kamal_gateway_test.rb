require "test_helper"

class KamalGatewayTest < ActiveSupport::TestCase
  test "exposes Conductor verbs while translating to Kamal 2.12 grammar" do
    gateway = KamalGateway.new(destination: "production")

    assert_equal "app exec --reuse bin/rails\\ db:migrate -d production", gateway.exec_live("bin/rails db:migrate")
    assert_equal "app logs -n 20 -d production", gateway.logs(lines: 20)
    assert_equal "app maintenance --message planned -d production", gateway.maintenance(message: "planned")
    assert_equal "deploy -d production", gateway.deploy
  end

  test "enforces the minimum installed Kamal version contract" do
    assert_operator KamalCommand.installed_version, :>=, KamalCommand::MINIMUM_VERSION
    assert_equal Gem::Version.new("2.12.0"), KamalCommand.assert_supported!
  end
end
