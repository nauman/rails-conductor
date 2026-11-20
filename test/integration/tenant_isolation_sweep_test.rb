require "test_helper"

# Plan 02 § 6: the isolation checks that must pass before open sign-up.
#
# The setup is the realistic worst case: an OPERATOR org (admin-owned, vetted)
# holding the platform's servers, a shared Postgres cluster, a Cloudflare
# account, the instance GitHub App, backup storage and keys; and an ATTACKER — a
# signed-up tenant already promoted to `trusted`, so trust gates never mask a
# scoping hole. Every check asks one question: can the attacker see or touch
# anything of the operator's?
module TenantIsolationFixtures
  MARKERS = [ "9.9.9.9", "edge-1", "platform-app", "shared-pg", "platform_db", "cf-platform-secret",
              "Platform CF", "platform-backups", "platform-key", "platform-cron", "platform-script",
              "platform-acct", "platform-zone-id" ].freeze

  def build_world
    @admin = User.create!(email: "ops@example.com", admin: true)
    @operator = Organization.create_for(@admin, name: "operator")
    @operator.update!(onboarded_at: Time.current)
    @p_key = @operator.ssh_keys.create!(name: "platform-key", private_key: valid_private_key)
    @p_server = @operator.servers.create!(name: "edge-1", ip_address: "9.9.9.9", status: "online", ssh_key: @p_key)
    @p_app = @operator.apps.create!(name: "platform-app", slug: "platform-app", server: @p_server, deploy_method: "docker",
                                    repository_url: "https://github.com/operator/platform.git")
    @p_cluster = DatabaseCluster.new(organization: @operator, server: @p_server, name: "shared-pg",
                                     container_name: "shared-pg", admin_username: "postgres")
    @p_cluster.save!(validate: false)
    @p_db = Database.new(organization: @operator, database_cluster: @p_cluster, name: "platform_db", username: "platform_db")
    @p_db.save!(validate: false)
    @p_cf = @operator.credentials.create!(name: "Platform CF", provider: "cloudflare", api_key: "cf-platform-secret", active: true)
    # The operator's account owns platform-zone.test, verified and cached — the
    # shape a zone resolver would find if it ever looked outside the tenant.
    @p_cf.update_columns(account_id: "platform-acct", verified_at: Time.current,
                         zones: [ { "id" => "platform-zone-id", "name" => "platform-zone.test" } ].to_json)
    @p_gh_app = Credential.create!(name: "GitHub App", provider: "github_app", api_key: "123", api_secret: "pem", active: true)
    @p_backup = @operator.backups.create!(provider: "aws_s3", bucket_name: "platform-backups", enabled: true, server: @p_server)
    @p_cron = CronJob.new(organization: @operator, server: @p_server, name: "platform-cron", command: "true",
                          cron_expression: "0 * * * *", schedule: "hourly")
    @p_cron.save!(validate: false)
    @p_script = @operator.scripts.create!(name: "platform-script", body: "echo platform", script_type: "provision")
    @p_pull = DatabasePull.new(organization: @operator, server: @p_server, app: @p_app)
    @p_pull.save!(validate: false)
    @p_membership = @operator.memberships.find_by!(user: @admin)
    @p_token, = ApiToken.generate(user: @admin, name: "platform-token", organization: @operator)
    @p_token_row = ApiToken.find_by!(organization: @operator)

    @attacker, @tenant = signed_up_tenant(email: "attacker@example.com")
    @tenant.change_trust!("trusted", reason: "test: strongest attacker")
    @t_key = @tenant.ssh_keys.create!(name: "tenant-key", private_key: valid_private_key)
    @t_server = @tenant.servers.create!(name: "tenant-box", ip_address: "8.8.8.8", status: "online", ssh_key: @t_key,
                                        ownership_verified_at: Time.current)
    @t_app = @tenant.apps.create!(name: "tenant-app", slug: "tenant-app", server: @t_server, deploy_method: "docker",
                                  repository_url: "https://github.com/tenant/app.git")
  end

  def victim_snapshot
    [ @p_server, @p_app, @p_cluster, @p_db, @p_cf, @p_gh_app, @p_backup, @p_cron, @p_script, @p_pull, @p_key,
      @p_membership, @p_token_row ].map { |r| r.class.unscoped.find_by(id: r.id)&.attributes }
  end

  def refute_markers(text, context)
    MARKERS.each { |m| refute_includes text.to_s, m, "#{context} leaked #{m.inspect}" }
  end
end

class TenantIsolationSweepTest < ActionDispatch::IntegrationTest
  include TenantIsolationFixtures

  setup do
    build_world
    @before = victim_snapshot
    ps = Passwordless::Session.create!(authenticatable: @attacker)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  teardown do
    assert_equal @before, victim_snapshot, "an operator record changed during an attacker request" if @before
  end

  # ---- § 6 item 1: every org-owned model, generated --------------------------

  # model => requests the attacker makes against the operator's row. Each must
  # come back 404 (or, for writes, change nothing — the teardown checks that).
  def web_probes
    {
      Server        => [ [ :get, server_path(@p_server) ], [ :get, edit_server_path(@p_server) ],
                         [ :patch, server_path(@p_server), { server: { name: "pwned" } } ], [ :delete, server_path(@p_server) ] ],
      App           => [ [ :get, app_path(@p_app) ], [ :get, edit_app_path(@p_app) ],
                         [ :patch, app_path(@p_app), { app: { name: "pwned" } } ], [ :delete, app_path(@p_app) ] ],
      Backup        => [ [ :get, backup_path(@p_backup) ], [ :get, edit_backup_path(@p_backup) ],
                         [ :patch, backup_path(@p_backup), { backup: { bucket_name: "pwned" } } ], [ :delete, backup_path(@p_backup) ] ],
      Credential    => [ [ :get, edit_credential_path(@p_cf) ],
                         [ :patch, credential_path(@p_cf), { credential: { name: "pwned" } } ], [ :delete, credential_path(@p_cf) ] ],
      SshKey        => [ [ :get, ssh_key_path(@p_key) ], [ :get, edit_ssh_key_path(@p_key) ],
                         [ :patch, ssh_key_path(@p_key), { ssh_key: { name: "pwned" } } ], [ :delete, ssh_key_path(@p_key) ] ],
      Script        => [ [ :get, script_path(@p_script) ], [ :get, edit_script_path(@p_script) ],
                         [ :patch, script_path(@p_script), { script: { name: "pwned" } } ], [ :delete, script_path(@p_script) ] ],
      DatabaseCluster => [ [ :get, database_cluster_path(@p_cluster) ],
                           [ :post, database_cluster_databases_path(@p_cluster), { database: { name: "stolen" } } ] ],
      Database      => [ [ :delete, database_path(@p_db) ] ],
      DatabasePull  => [ [ :get, database_pull_path(@p_pull) ] ],
      CronJob       => [ [ :patch, server_cron_job_path(@t_server, @p_cron), { cron_job: { name: "pwned" } } ],
                         [ :delete, server_cron_job_path(@t_server, @p_cron) ],
                         [ :delete, server_cron_job_path(@p_server, @p_cron) ] ],
      Membership    => [ [ :patch, member_path(@p_membership), { membership: { role: "member" } } ], [ :delete, member_path(@p_membership) ] ],
      ApiToken      => [ [ :delete, mcp_token_path(@p_token_row) ] ]
    }
  end

  # Org-owned models with no by-id web route, and why that is safe. A new model
  # with organization_id must land in one of the two maps or this suite fails.
  NOT_WEB_ADDRESSABLE = {
    "Invitation"     => "accepted only by its unguessable token",
    "McpCall"        => "listed only on the admin-only MCP call log",
    "AppTransfer"    => "reached only through its app (App probes cover it)",
    "Decommission"   => "reached only through its app (App probes cover it)",
    "StorageBucket"  => "reached only through conductor_storage (MCP sweep covers it)",
    "AbuseFlag"      => "no tenant surface; admin-only",
    "TrustEvent"     => "no tenant surface; admin-only"
  }.freeze

  test "every model with organization_id is covered by a probe or explained" do
    Rails.application.eager_load!
    org_owned = ApplicationRecord.descendants.reject(&:abstract_class?)
                                 .select { |m| m.table_exists? && m.column_names.include?("organization_id") }.map(&:name)
    covered = web_probes.keys.map(&:name) + NOT_WEB_ADDRESSABLE.keys
    assert_empty org_owned - covered, "org-owned models with no isolation probe — add one"
  end

  test "the attacker gets 404 for every operator row, and changes nothing" do
    web_probes.each do |model, probes|
      probes.each do |verb, path, params|
        send(verb, path, params: params || {})
        assert_includes [ 404 ], response.status, "#{model} #{verb.upcase} #{path} answered #{response.status}"
        refute_markers(response.body, "#{model} #{verb.upcase} #{path}")
      end
    end
  end

  # ---- § 6 item 9 / 13: no platform resource on any tenant page ------------

  test "no tenant page names a platform resource" do
    [ root_path, servers_path, apps_path, backups_path, credentials_path, ssh_keys_path, scripts_path,
      database_clusters_path, database_pulls_path, members_path, mcp_tokens_path, organizations_path,
      onboarding_server_path, onboarding_agent_path ].each do |path|
      get path
      refute_markers(response.body, "GET #{path}")
    end
  end

  test "admin-only pages are 404-or-redirect for a tenant owner, never content" do
    [ admin_root_path, admin_organizations_path, admin_users_path, admin_mcp_calls_path, users_path, integrations_path ].each do |path|
      get path
      refute response.successful?, "#{path} served a tenant owner"
      refute_markers(response.body, "GET #{path}")
    end
  end

  # ---- § 6 item 2: global uniqueness leaks -----------------------------------

  test "server names are per organization, so a collision reveals nothing" do
    assert @tenant.servers.new(name: "edge-1", ip_address: "1.1.1.1", status: "offline").valid?
  end

  test "app slugs stay instance-unique (they key control-plane paths) and the collision names nothing" do
    clash = @tenant.apps.new(name: "x", slug: "platform-app", server: @t_server, deploy_method: "docker",
                             repository_url: "https://github.com/tenant/x.git")
    refute clash.valid?
    assert_equal [ "has already been taken" ], clash.errors[:slug]
    refute_markers(clash.errors.full_messages.join, "slug collision")
    # Why it stays global: KamalDeployer keys its checkout and key files by slug
    # on the control plane. Per-org slugs would let two orgs share a directory.
    assert_equal File.join(KamalDeployer.new(@p_app, @p_app.deployments.new).send(:workspace), "platform-app"),
                 KamalDeployer.new(@p_app, @p_app.deployments.new).send(:checkout_dir)
  end

  # ---- § 6 item 3: org-less rows ---------------------------------------------

  test "nullified (org-less) rows are visible to admins only; built-in scripts are the one global" do
    orphan = Server.create!(name: "orphan", ip_address: "7.7.7.7", status: "online")
    get server_path(orphan)
    assert_response :not_found
    get servers_path
    refute_includes response.body, "7.7.7.7"

    builtin = Script.create!(name: "builtin-probe", body: "uptime", script_type: "provision", built_in: true)
    assert_includes Script.visible_to(@tenant), builtin
    refute_includes Script.visible_to(@tenant), @p_script
  end

  test "no query outside the allowlist treats organization_id nil as visible to everyone" do
    allowed = {
      "app/models/script.rb" => "built-in scripts are global by design",
      "app/services/native_deployer.rb" => "built-in scripts are global by design",
      "app/tools/set_github_app_tool.rb" => "admin-only instance GitHub App",
      "app/services/egress_guard.rb" => "reserves org-less (operator) addresses; restricts, never grants"
    }
    offenders = Dir[Rails.root.join("app/**/*.rb")].select do |f|
      File.read(f).match?(/organization_id:\s*nil|organization_id IS NULL|organization:\s*nil\b(?!\))/)
    end.map { |f| f.delete_prefix("#{Rails.root}/") }
    offenders -= %w[app/models/mcp_call.rb app/models/api_token.rb] # keyword-argument defaults, not queries
    assert_empty offenders - allowed.keys, "new nil-organization query — prove it is not a global grant, then allowlist it"
  end

  # ---- § 6 item 7: no cross-org attachment, generated -----------------------

  test "no org-owned record accepts an association to another org's record" do
    Rails.application.eager_load!
    victims = { Server => @p_server, App => @p_app, SshKey => @p_key, DatabaseCluster => @p_cluster,
                Credential => @p_cf, Backup => @p_backup }
    candidates = {
      Server => -> { @tenant.servers.new(name: "n", ip_address: "1.1.1.1", status: "offline") },
      App => -> { @tenant.apps.new(name: "n", slug: "n-#{SecureRandom.hex(2)}", server: @t_server, deploy_method: "docker",
                                   repository_url: "https://github.com/tenant/n.git") },
      Backup => -> { @tenant.backups.new(provider: "aws_s3", bucket_name: "tenant-bucket", enabled: false) },
      CronJob => -> { CronJob.new(organization: @tenant, server: @t_server, name: "c", command: "true", cron_expression: "0 * * * *", schedule: "hourly") },
      DatabaseCluster => -> { DatabaseCluster.new(organization: @tenant, server: @t_server, name: "c", container_name: "c", admin_username: "postgres") },
      Database => -> { Database.new(organization: @tenant, name: "d", username: "d") },
      DatabasePull => -> { DatabasePull.new(organization: @tenant, server: @t_server, app: @t_app) }
    }
    holes = []
    candidates.each do |model, build|
      model.reflect_on_all_associations(:belongs_to).each do |assoc|
        next if assoc.polymorphic? || assoc.name == :organization
        victim = victims[assoc.klass] rescue nil
        next unless victim

        record = build.call
        record.public_send("#{assoc.name}=", victim)
        holes << "#{model}##{assoc.name}" if record.valid?
      end
    end
    assert_empty holes, "these accept another org's record"
  end

  # ---- § 6 item 8: webhooks --------------------------------------------------

  test "a push webhook signed with the tenant's secret cannot trigger the operator's app" do
    body = { ref: "refs/heads/main", after: "abc" }.to_json
    sig = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", @t_app.webhook_secret.to_s, body)
    post "/webhooks/#{@p_app.id}", params: body, headers: { "Content-Type" => "application/json", "X-Hub-Signature-256" => sig }
    assert_includes [ 401, 404 ], response.status
    assert_equal 0, @p_app.deployments.count
  end

  # ---- § 6 item 10: GitHub App clone token -----------------------------------

  test "the instance GitHub App never mints a clone token for a signed-up org's app" do
    with_open_signup do
      deployer = KamalDeployer.new(@t_app, @t_app.deployments.new)
      GithubApp.stub(:from_config, -> { flunk "must not even load the App for a tenant" }) do
        assert_nil deployer.send(:resolve_clone_token)
      end
    end
  end

  # ---- § 6 item 11: shared cluster attach ------------------------------------

  test "the attacker cannot place a database on the operator's cluster by id (web) or name (MCP)" do
    post database_cluster_databases_path(@p_cluster), params: { database: { name: "stolen" } }
    assert_response :not_found

    result = mcp_as_attacker("conductor_database", "action" => "provision", "app_id" => @t_app.id, "cluster_name" => "shared-pg")
    refute result.success?
    assert_equal 0, Database.where(name: "stolen").or(Database.where(database_cluster: @p_cluster).where.not(id: @p_db.id)).count
  end

  # ---- § 6 item 12: legacy shared token --------------------------------------

  test "the legacy shared MCP token is refused in open mode for reads and writes" do
    with_open_signup("CONDUCTOR_MCP_TOKEN" => "legacy-shared") do
      post "/mcp/call", params: { name: "conductor_read", input: { action: "fleet_status" } },
           headers: { "Authorization" => "Bearer legacy-shared" }, as: :json
      assert_response :unauthorized
      post "/mcp/call", params: { name: "conductor_app", input: { action: "deploy", app_id: @p_app.id } },
           headers: { "Authorization" => "Bearer legacy-shared" }, as: :json
      assert_response :unauthorized
    end
  end

  # ---- § 6 item 13: streamed logs --------------------------------------------

  test "a tenant's deploy and script logs never carry control-plane paths or the Docker host" do
    dep = @t_app.deployments.create!(status: "deploying")
    dep.append_log("cd #{Rails.root}/tmp/kamal/tenant-app && DOCKER_HOST=ssh://deploy@10.0.0.2 kamal build")
    refute_includes dep.reload.log, Rails.root.to_s
    refute_includes dep.log, "10.0.0.2"
    assert_includes dep.log, "DOCKER_HOST=[conductor]"

    run = ScriptRun.create!(server: @t_server, script: Script.create!(name: "s", body: "x", script_type: "provision", organization: @tenant))
    run.append_log("#{Rails.root}/bin/conductor")
    refute_includes run.reload.log, Rails.root.to_s

    op = @p_app.deployments.create!(status: "deploying")
    op.append_log("cd #{Rails.root}")
    assert_includes op.reload.log, Rails.root.to_s, "the operator's own logs are untouched"
  end

  # ---- § 6 item 14: admin -----------------------------------------------------

  test "no sign-up, invitation or user path can set admin" do
    intent, = SignupIntent.start!(email: "x@example.com", ip: "192.0.2.9")
    refute intent.consume!.admin?

    invitation = @tenant.invitations.create!(email: "invitee@example.com", invited_by: @attacker, role: :owner)
    invitee = User.fetch_resource_for_passwordless("invitee@example.com")
    refute invitee.admin?
    assert invitation.reload.accepted_at

    post users_path, params: { user: { email: "made@example.com", admin: "1" } }
    refute User.find_by(email: "made@example.com")&.admin?
    patch toggle_admin_user_path(@attacker)
    refute @attacker.reload.admin?
  end

  private

  def mcp_as_attacker(tool, input)
    Current.set(user: @attacker, organization: @tenant, org_scoped: true, read_only: false) do
      ToolRegistry.call(tool, input, user: @attacker)
    end
  end
end

# § 6 items 4, 9, 13: every MCP tool and every action, called by the attacker's
# org-bound token context with the operator's identifiers. Nothing may resolve,
# change or be named.
class TenantIsolationMcpSweepTest < ActiveSupport::TestCase
  include TenantIsolationFixtures

  setup do
    build_world
    @p_deployment = @p_app.deployments.create!(status: "succeeded")
  end

  def victim_input(action)
    {
      "action" => action,
      "app_id" => @p_app.id, "app_name" => "platform-app", "server_id" => @p_server.id, "server_name" => "edge-1",
      "from_server_name" => "edge-1", "target_server_name" => "edge-1", "cluster_id" => @p_cluster.id, "cluster_name" => "shared-pg",
      "database_id" => @p_db.id, "database_name" => "platform_db", "backup_id" => @p_backup.id, "cron_job_id" => @p_cron.id,
      "script_name" => "platform-script", "ssh_key_name" => "platform-key", "credential_id" => @p_cf.id,
      "deployment_id" => @p_deployment.id, "domain" => "www.platform-zone.test",
      "hostname" => "www.platform-zone.test", "zone" => "platform-zone.test", "name" => "probe-name", "key" => "SECRET", "value" => "x", "repo" => "operator/platform",
      "task" => "about", "ruby" => "1", "command" => "true", "version" => "v1"
    }
  end

  test "no tool, no action, resolves or reveals an operator resource" do
    outbound = []
    blocked_http = ->(host, *_rest, **_opts) { outbound << host; raise "outbound HTTP refused in the isolation sweep" }
    leaks = []
    before = victim_snapshot

    Net::HTTP.stub(:start, blocked_http) do
      ToolRegistry::TOOLS.each do |tool|
        name = tool::DEFINITION[:name]
        actions = defined?(tool::ACTIONS) ? tool::ACTIONS.keys : tool::DEFINITION.dig(:input_schema, :properties, :action, :enum)
        assert actions.present?, "#{name} exposes no action list to sweep"
        actions.each do |action|
          result = Current.set(user: @attacker, organization: @tenant, org_scoped: true, read_only: false) do
            ToolRegistry.call(name, victim_input(action), user: @attacker)
          end
          text = [ result.value, result.error ].to_json
          MARKERS.each { |m| leaks << "#{name}/#{action} → #{m}" if text.include?(m) }
        end
      end
    end

    assert_empty leaks, "MCP results named operator resources"
    assert_empty outbound.grep(/cloudflare/), "a tenant call reached Cloudflare — only the operator's token exists, so it used it"
    assert_equal before, victim_snapshot, "an MCP call changed an operator record"
    assert_equal 1, @p_app.deployments.count, "no deploy was started on the operator's app"
    assert_equal 0, ScriptRun.where(server: @p_server).count
  end
end

# § 6 item 5: Action Cable streams.
class TenantIsolationCableTest < ActionCable::Channel::TestCase
  include TenantIsolationFixtures

  setup { build_world }

  test "the attacker cannot subscribe to the operator's deploy, script or pull streams" do
    dep = @p_app.deployments.create!(status: "deploying")
    run = ScriptRun.create!(server: @p_server, script: @p_script)
    { DeployChannel => { deployment_id: dep.id }, ScriptRunChannel => { script_run_id: run.id },
      DatabasePullChannel => { database_pull_id: @p_pull.id } }.each do |channel, params|
      self.class.tests(channel)
      stub_connection(current_user: @attacker)
      subscribe(**params)
      assert subscription.rejected?, "#{channel} accepted the attacker"
    end
  end
end

# § 6 item 6: jobs fail closed for a suspended org.
class TenantIsolationJobsTest < ActiveSupport::TestCase
  include TenantIsolationFixtures

  setup do
    build_world
    @tenant.suspend!(by: @admin)
  end

  test "no job dials a suspended org's server" do
    dialled = []
    fake = ->(host, *_a, **_o) { dialled << host; raise Errno::ECONNREFUSED }
    with_signup_env("ALLOW_TEST_SSH" => "1") do
      Net::SSH.stub(:start, fake) do
        dep = @t_app.deployments.create!(status: "pending")
        DeployAppJob.perform_now(dep.id) rescue nil
        RefreshServerMetricsJob.perform_now(@t_server.id) rescue nil
        ServerAuditCheckJob.perform_now(@t_server.id) rescue nil
        SyncContainerStatusJob.perform_now(@t_app.id) rescue nil
      end
    end
    assert_empty dialled
  end

  test "a suspended org cannot start a deploy at all" do
    _, status, policy = @t_app.start_deployment!(force: true)
    assert_equal :blocked, status
    assert_match(/suspended/, policy.checks.first.detail)
  end
end
