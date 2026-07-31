require "test_helper"

# ADR 0004 — infra_revision is only worth having if it is always right. These
# tests are mostly about the ways it could quietly become wrong.
class AppFormChangeTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @a = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1")
    @b = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2")
    @user = User.create!(email: "op@example.com")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @a,
                             deploy_method: "docker", repository_url: "https://github.com/x/y.git")
  end

  test "a new app starts at revision 1" do
    assert_equal 1, @app.infra_revision
    assert_equal "#{@app.id}.1", @app.infra_identity
  end

  test "moving box bumps the revision and records what changed" do
    AppFormChange.new(@app, user: @user).apply!(server_id: @b.id, reason: "migrated to ops2")

    assert_equal 2, @app.reload.infra_revision
    rev = @app.infra_revisions.recent.first
    assert_equal 2, rev.revision
    assert_equal [ @a.id, @b.id ], rev.changes_made["server_id"]
    assert_equal "migrated to ops2", rev.reason
    assert_equal @user, rev.user
  end

  test "switching deploy method is a form change" do
    AppFormChange.new(@app).apply!(deploy_method: "kamal")

    assert_equal 2, @app.reload.infra_revision
    assert_equal %w[docker kamal], @app.infra_revisions.recent.first.changes_made["deploy_method"]
  end

  test "several fields changing at once is ONE revision, not one each" do
    AppFormChange.new(@app).apply!(server_id: @b.id, deploy_method: "kamal")

    assert_equal 2, @app.reload.infra_revision
    assert_equal 1, @app.infra_revisions.count
  end

  # A revision that counts non-events is as misleading as one that misses events.
  test "re-applying the same values does not inflate the revision" do
    AppFormChange.new(@app).apply!(server_id: @a.id, deploy_method: "docker")

    assert_equal 1, @app.reload.infra_revision
    assert_equal 0, @app.infra_revisions.count
  end

  # The whole point of the choke point. Only bites once the app has actually put
  # something on a box — before that there is no residue to strand.
  test "changing a form field OUTSIDE AppFormChange is refused" do
    @app.update_column(:deployed_at, Time.current)
    assert_not @app.reload.update(server_id: @b.id)
    assert_match(/infrastructure form/i, @app.errors.full_messages.to_sentence)
    assert_equal @a.id, @app.reload.server_id
    assert_equal 1, @app.infra_revision
  end

  test "an app that has never deployed may be shaped freely" do
    assert @app.update(server_id: @b.id, deploy_method: "kamal"),
           "no residue exists yet, so this is configuration not a form change"
    assert_equal 1, @app.reload.infra_revision
  end

  test "ordinary config edits are unaffected" do
    @app.update_column(:deployed_at, Time.current)
    assert @app.reload.update(notes: "hello", port: 4000, branch: "hotfix")
    assert_equal 1, @app.reload.infra_revision
  end

  test "a non-form field passed to apply! is rejected loudly" do
    assert_raises(AppFormChange::NotAFormChange) do
      AppFormChange.new(@app).apply!(notes: "nope")
    end
  end

  test "the resource key is stable across renames and form changes" do
    key = @app.resource_key
    assert_equal "app-#{@app.id}", key

    @app.update!(name: "Renamed", slug: "renamed")
    AppFormChange.new(@app).apply!(server_id: @b.id, deploy_method: "kamal")

    assert_equal key, @app.reload.resource_key, "identity must survive rename AND form change"
  end

  test "container names carry the revision so residue is detectable" do
    assert_equal "app-#{@app.id}-r1-abc1234", @app.release_container_name("abc1234def")

    AppFormChange.new(@app).apply!(server_id: @b.id)

    assert_equal "app-#{@app.id}-r2-abc1234", @app.reload.release_container_name("abc1234def"),
                 "a container from r1 is now recognisably stale"
  end

  # deployed_at and container_id are both clearable; deployment history is not.
  test "ever_deployed? survives deployed_at and container_id being cleared" do
    @app.deployments.create!(status: "succeeded")
    @app.update_columns(deployed_at: nil, container_id: nil)

    assert @app.reload.ever_deployed?, "successful deploy history is the durable signal"
    assert_not @app.update(server_id: @b.id), "the guard must still bite"
  end

  test "a failed form change leaves the revision untouched" do
    assert_raises(ActiveRecord::RecordInvalid) do
      AppFormChange.new(@app).apply!(deploy_method: "nonsense")
    end

    assert_equal 1, @app.reload.infra_revision
    assert_equal 0, @app.infra_revisions.count
  end
end
