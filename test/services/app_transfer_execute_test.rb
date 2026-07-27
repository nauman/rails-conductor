require "test_helper"

# App-transfer spec 26: AppTransferRunner::Execute is the real orchestration —
# it composes the transfer phases via a `deps` binding. These verify the wiring
# (right calls, right order, right args) with a fake binding; FleetDeps binds the
# real primitives.
class AppTransferExecuteTest < ActiveSupport::TestCase
  TargetDb = Struct.new(:database_url)

  class FakeDeps
    attr_reader :calls
    def initialize(target_db:)
      @calls = []
      @target_db = target_db
    end
    def provision_target_db! = (@calls << :provision; @target_db)
    def replicate!(source_url:, target_url:) = @calls << [ :replicate, source_url, target_url ]
    def deploy_to_target! = @calls << :deploy
    def publish_edge!(domain:) = @calls << [ :edge, domain ]
    def repoint_dns!(domain:, ip:) = @calls << [ :dns, domain, ip ]
    def stop_source! = @calls << :stop
  end

  setup do
    user = User.create!(email: "exec@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "a", status: "online", ip_address: "10.0.0.1", ssh_key: key, ssh_user: "deploy", edge_type: "caddy")
    @target = @org.servers.create!(name: "b", status: "online", ip_address: "10.0.0.2", ssh_key: key, ssh_user: "deploy", edge_type: "caddy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "app.example.com")
    # A dedicated DB on the SOURCE, so the source URL resolves.
    cluster = @org.database_clusters.create!(server: @source, name: "appone-db", container_name: "appone-db",
                                             admin_username: "conductor", admin_password: "x", port: 5432)
    cluster.databases.create!(organization: @org, app: @app, name: "appone", username: "appone", password: "pw", status: "active")
    @transfer = AppTransfer.create!(app: @app, organization: @org, source_server: @source, target_server: @target)
  end

  test "the full pipeline runs each phase against the deps in the correct order" do
    deps = FakeDeps.new(target_db: TargetDb.new("postgres://appone:pw@appone-db:5432/appone"))
    exec = AppTransferRunner::Execute.new(@transfer, deps: deps)

    assert AppTransferRunner.new(@transfer, collaborators: exec).run

    src_url = "postgres://appone:pw@appone-db:5432/appone"
    assert_equal(
      [ :provision, [ :replicate, src_url, "postgres://appone:pw@appone-db:5432/appone" ],
        :deploy, [ :edge, "app.example.com" ], [ :dns, "app.example.com", "10.0.0.2" ], :stop ],
      deps.calls
    )
    assert @transfer.reload.succeeded?
  end

  test "clone runs everything except drain (source stays live)" do
    @transfer.update!(mode: "clone")
    deps = FakeDeps.new(target_db: TargetDb.new("postgres://target"))
    AppTransferRunner.new(@transfer, collaborators: AppTransferRunner::Execute.new(@transfer, deps: deps)).run

    refute_includes deps.calls, :stop
    assert_equal :provision, deps.calls.first
  end

  test "an app with no domain skips edge + dns cutover" do
    @app.update!(domain: nil)
    deps = FakeDeps.new(target_db: TargetDb.new("postgres://target"))
    AppTransferRunner.new(@transfer, collaborators: AppTransferRunner::Execute.new(@transfer, deps: deps)).run

    refute(deps.calls.any? { |c| c.is_a?(Array) && [ :edge, :dns ].include?(c.first) })
  end
end
