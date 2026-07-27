require "test_helper"

# App-transfer spec 26, Slice 6: the orchestration engine. These exercise the
# ENGINE (phase order, clone semantics, failure handling, persisted progress)
# with an injected collaborator — no real infrastructure is touched.
class AppTransferRunnerTest < ActiveSupport::TestCase
  class FakeCollaborators
    attr_reader :calls
    def initialize = @calls = []
    def deploy_to_target = @calls << :compute
    def replicate_database = @calls << :database
    def publish_on_target_edge = @calls << :edge
    def cut_over = @calls << :cutover
    def drain_source = @calls << :drain
  end

  class FailAtDatabase < FakeCollaborators
    def replicate_database
      @calls << :database
      raise "replication blew up"
    end
  end

  setup do
    user = User.create!(email: "runner@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "a", status: "online", ip_address: "10.0.0.1", ssh_key: @key, ssh_user: "deploy")
    @target = @org.servers.create!(name: "b", status: "online", ip_address: "10.0.0.2", ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git")
  end

  def transfer(mode: "transfer")
    AppTransfer.create!(app: @app, organization: @org, source_server: @source, target_server: @target, mode: mode)
  end

  test "runs every phase in order and records success" do
    fc = FakeCollaborators.new
    t = transfer
    assert AppTransferRunner.new(t, collaborators: fc).run

    assert_equal %i[database compute edge cutover drain], fc.calls
    assert t.reload.succeeded?
    assert_equal "drain", t.phase
    assert t.finished_at.present?
  end

  test "clone skips drain, leaving the source live" do
    fc = FakeCollaborators.new
    t = transfer(mode: "clone")
    AppTransferRunner.new(t, collaborators: fc).run

    assert_equal %i[database compute edge cutover], fc.calls
    refute_includes fc.calls, :drain
    assert t.reload.succeeded?
  end

  test "a failing phase marks the transfer failed at that phase and stops" do
    fc = FailAtDatabase.new
    t = transfer
    refute AppTransferRunner.new(t, collaborators: fc).run

    assert_equal %i[database], fc.calls, "database is first; it fails and nothing after runs"
    assert t.reload.failed?
    assert_equal "database", t.phase
    assert_match(/database/, t.error)
  end

  test "the default collaborators refuse to run against real infrastructure" do
    t = transfer
    refute AppTransferRunner.new(t).run

    assert t.reload.failed?
    assert_equal "database", t.phase, "fails at the very first mutating step"
    assert_match(/not wired/i, t.error)
  end

  test "target must differ from the source server" do
    bad = AppTransfer.new(app: @app, organization: @org, source_server: @source, target_server: @source)
    refute bad.valid?
    assert_includes bad.errors[:target_server], "must differ from the source server"
  end
end
