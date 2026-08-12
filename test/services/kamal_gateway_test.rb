require "test_helper"

class KamalGatewayTest < ActiveSupport::TestCase
  test "exposes Conductor verbs while translating to Kamal 2 grammar" do
    gateway = KamalGateway.new(destination: "production")

    assert_equal "app exec --reuse bin/rails\\ db:migrate -d production", gateway.exec_live("bin/rails db:migrate")
    assert_equal "app logs -n 20 -d production", gateway.logs(lines: 20)
    assert_equal "app maintenance --message planned -d production", gateway.maintenance(message: "planned")
    assert_equal "deploy -d production", gateway.deploy
  end

  test "enforces the minimum installed Kamal version contract" do
    assert_operator KamalCommand.installed_version, :>=, KamalCommand::MINIMUM_VERSION
    # Returns what is INSTALLED, not the floor: a literal here re-broke the moment the
    # pin moved, and asserting the constant against itself would prove nothing.
    assert_equal KamalCommand.installed_version, KamalCommand.assert_supported!
  end

  test "refuses a CLI older than the grammar floor" do
    older = Gem::Version.new("2.9.0")
    KamalCommand.stub(:installed_version, older) do
      error = assert_raises(RuntimeError) { KamalCommand.assert_supported! }
      assert_match(/2\.9\.0/, error.message)
    end
  end
end
