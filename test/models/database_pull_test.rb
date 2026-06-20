require "test_helper"

class DatabasePullTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "dp@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.5", ssh_key: key)
  end

  test "status predicates" do
    pull = DatabasePull.new(server: @server, status: "pending")
    assert pull.pending?
    refute pull.done?

    pull.status = "running"
    assert pull.running?

    pull.status = "success"
    assert pull.success?
    assert pull.done?

    pull.status = "failed"
    assert pull.failed?
    assert pull.done?
  end

  test "restore? reflects restore_target presence" do
    refute DatabasePull.new(server: @server).restore?
    assert DatabasePull.new(server: @server, restore_target: "mydb").restore?
  end

  test "validates source_database_url_var presence" do
    pull = DatabasePull.new(server: @server, source_database_url_var: "", status: "pending")
    refute pull.valid?
    assert_includes pull.errors.attribute_names, :source_database_url_var
  end

  test "formatted_size humanizes bytes" do
    assert_equal "—", DatabasePull.new(server: @server, size_bytes: 0).formatted_size
    assert_equal "1.0 KB", DatabasePull.new(server: @server, size_bytes: 1024).formatted_size
    assert_equal "72.3 KB", DatabasePull.new(server: @server, size_bytes: 74_007).formatted_size
  end

  test "source_label falls back to the url var" do
    assert_equal "db_prod", DatabasePull.new(server: @server, source_database: "db_prod").source_label
    assert_equal "DATABASE_URL", DatabasePull.new(server: @server, source_database_url_var: "DATABASE_URL").source_label
  end

  test "append_log accumulates and persists" do
    pull = DatabasePull.create!(server: @server, organization: @org, status: "pending")
    pull.append_log("line one\n")
    pull.append_log("line two\n")
    assert_equal "line one\nline two\n", pull.reload.log
  end

  test "duration is nil until both timestamps set" do
    pull = DatabasePull.new(server: @server)
    assert_nil pull.duration
    pull.started_at = Time.current - 5.seconds
    pull.completed_at = Time.current
    assert_equal 5, pull.duration
  end
end
