require "test_helper"

# Plan 02 § 5.3 / § 9 steps 3, 5, 9: trust levels, the limits a `new` org runs
# under, the control-plane boundary, promotion and suspension — denied the same
# way on web, API and MCP.
class TenantTrustTest < ActionDispatch::IntegrationTest
  setup do
    @owner, @org = signed_up_tenant
    @server = @org.servers.create!(name: "web-1", ip_address: "8.8.8.8", status: "online",
                                   ssh_key: @org.ssh_keys.create!(name: "k", private_key: valid_private_key))
    @script = @org.scripts.create!(name: "probe", body: "echo hi", script_type: "provision")
    @raw, = ApiToken.generate(user: @owner, name: "t", organization: @org)
  end

  def sign_in(user)
    ps = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{ps.identifier}/#{ps.token}"
  end

  def mcp(name, input)
    post "/mcp/call", params: { name: name, input: input },
         headers: { "Authorization" => "Bearer #{@raw}" }, as: :json
  end

  # ---- policy ---------------------------------------------------------------

  test "a new owner keeps ordinary owner bands but not execute, chat or control builds" do
    assert OperatorPolicy.can?(@owner, @org, :deploy)
    assert OperatorPolicy.can?(@owner, @org, :credentials), "own credentials, encrypted per org"
    assert OperatorPolicy.can?(@owner, @org, :manage_members)
    refute OperatorPolicy.can?(@owner, @org, :execute)
    refute OperatorPolicy.can?(@owner, @org, :chat)
    refute OperatorPolicy.can?(@owner, @org, :control_build)
  end

  test "a promoted self-signed-up org gains execute and chat but never the control plane" do
    @org.change_trust!("trusted", reason: "test")
    assert OperatorPolicy.can?(@owner, @org, :execute)
    assert OperatorPolicy.can?(@owner, @org, :chat)
    refute OperatorPolicy.can?(@owner, @org, :control_build)
  end

  test "an invited org is unchanged: trusted, control plane allowed" do
    user = User.create!(email: "invited@example.com")
    org = Organization.create_for(user, name: "invited")
    assert_equal "trusted", org.trust_level
    assert OperatorPolicy.can?(user, org, :execute)
    assert OperatorPolicy.can?(user, org, :control_build)
  end

  test "a suspended org can do nothing, but the platform admin still can" do
    @org.suspend!(by: nil)
    refute OperatorPolicy.operator?(@owner, @org)
    %i[read deploy configure credentials destroy chat].each { |c| refute OperatorPolicy.can?(@owner, @org, c), c }
    assert OperatorPolicy.can?(User.create!(email: "root@example.com", admin: true), @org, :deploy)
  end

  test "in open mode a non-admin's extra org starts new and needs its own card check" do
    with_open_signup do
      org = Organization.create_for(@owner, name: "second")
      assert_equal "new", org.trust_level
      assert org.card_check_required?
    end
  end

  # ---- execute denied on all three surfaces ----------------------------------

  test "web: a new owner cannot reach scripts" do
    sign_in(@owner)
    get scripts_path
    assert_response :redirect
    refute_match(/probe/, response.body)
  end

  test "api: a new owner cannot run a script" do
    post "/api/v1/scripts/run", params: { script_id: @script.id, server_id: @server.id },
         headers: { "Authorization" => "Bearer #{@raw}" }
    assert_response :forbidden
  end

  test "mcp: a new owner cannot run a script or the runner" do
    mcp("conductor_server", { action: "run_script", server_name: "web-1", script_name: "probe" })
    assert_match(/requires an organization owner \(execute\)/, response.body)
    assert_equal 0, ScriptRun.count
  end

  test "web: chat is closed to a new org" do
    sign_in(@owner)
    get conversations_path
    assert_redirected_to root_path
  end

  # ---- control plane ---------------------------------------------------------

  test "a self-signed-up org's app defaults to building on its own server and cannot pick control" do
    app = @org.apps.create!(name: "a", slug: "tenant-a", server: @server, deploy_method: "docker",
                            repository_url: "https://github.com/x/y.git")
    assert_equal "target", app.build_venue
    app.build_venue = "control"
    refute app.valid?
    assert_match(/never run builds or Kamal on Conductor's own host/, app.errors[:build_venue].join)
  end

  test "Conductor never drives Kamal for a self-signed-up org, even a trusted one" do
    @org.change_trust!("trusted", reason: "test")
    app = @org.apps.new(name: "k", slug: "tenant-k", server: @server, deploy_method: "kamal", build_venue: "target",
                        repository_url: "https://github.com/x/y.git")
    app.save!(validate: false)
    deployment = app.deployments.create!(status: "pending")

    refute KamalDeployer.new(app, deployment).deploy!
    assert_equal "failed", deployment.reload.status
    assert_match(/never run builds or Kamal/, deployment.log.to_s)
    assert_match(/never run builds or Kamal/, KamalOps.new(app).unavailable_reason)

    blocked, status, = app.start_deployment!(force: true)
    assert_equal :blocked, status, "force does not override tenant policy"
    assert_equal "blocked", blocked.status
  end

  # ---- limits ----------------------------------------------------------------

  test "two servers, then a third is refused" do
    @org.servers.create!(name: "web-2", ip_address: "8.8.4.4", status: "offline")
    third = @org.servers.new(name: "web-3", ip_address: "1.1.1.1", status: "offline")
    refute third.valid?
    assert_match(/up to 2 servers/, third.errors.full_messages.join)
  end

  test "three invitations, then a fourth is refused" do
    3.times { |i| @org.invitations.create!(email: "i#{i}@example.com", invited_by: @owner) }
    fourth = @org.invitations.new(email: "i4@example.com", invited_by: @owner)
    refute fourth.valid?
  end

  test "an unvetted org cannot invite a platform admin" do
    User.create!(email: "boss@example.com", admin: true)
    invite = @org.invitations.new(email: "Boss@Example.com", invited_by: @owner, role: :owner)
    refute invite.valid?
    assert_equal [ "cannot be invited" ], invite.errors[:email]
  end

  test "one deploy at a time, not overridable" do
    @server.update_columns(ownership_verified_at: Time.current)
    a = @org.apps.create!(name: "a", slug: "tenant-a", server: @server, deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    b = @org.apps.create!(name: "b", slug: "tenant-b", server: @server, deploy_method: "docker", repository_url: "https://github.com/x/z.git")
    a.deployments.create!(status: "deploying")
    _, status, policy = b.start_deployment!(force: true)
    assert_equal :blocked, status
    assert_match(/1 deploy at a time/, policy.checks.first.detail)
  end

  test "an unverified server cannot be deployed to" do
    app = @org.apps.create!(name: "a", slug: "tenant-a", server: @server, deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    _, status, policy = app.start_deployment!(force: true)
    assert_equal :blocked, status
    assert_match(/has not proved ownership/, policy.checks.first.detail)
  end

  test "30 API/MCP calls a minute, then 429, and the overrun is an abuse flag" do
    TenantLimits.store = ActiveSupport::Cache::MemoryStore.new
    freeze_time do
      30.times { get "/api/v1/servers", headers: { "Authorization" => "Bearer #{@raw}" } }
      assert_response :success
      get "/api/v1/servers", headers: { "Authorization" => "Bearer #{@raw}" }
      assert_response :too_many_requests
      mcp("conductor_read", { action: "fleet_status" })
      assert_match(/Rate limit exceeded/, response.body)
    end
    assert_equal [ "api_throttle" ], @org.abuse_flags.pluck(:kind)
  ensure
    TenantLimits.store = nil
  end

  # ---- promotion -------------------------------------------------------------

  test "promotion: 7 clean days after the card check, recorded with its rule" do
    @org.update!(card_verified_at: 8.days.ago)
    PromoteTrustedOrganizationsJob.perform_now
    assert @org.reload.trusted?
    event = @org.trust_events.last
    assert_equal [ "new", "trusted", nil ], [ event.from_level, event.to_level, event.user_id ]
    assert_match(/option B/, event.reason)
  end

  test "promotion: not before 7 days, not with an abuse flag, never a suspended org" do
    @org.update!(card_verified_at: 6.days.ago)
    PromoteTrustedOrganizationsJob.perform_now
    assert @org.reload.new_tenant?

    @org.update!(card_verified_at: 8.days.ago)
    @org.flag_abuse!(:egress_refused, "10.0.0.1")
    PromoteTrustedOrganizationsJob.perform_now
    assert @org.reload.new_tenant?

    _, other = signed_up_tenant(email: "s@example.com")
    other.update!(card_verified_at: 8.days.ago)
    other.suspend!(by: nil)
    PromoteTrustedOrganizationsJob.perform_now
    assert other.reload.suspended?
  end

  # ---- suspension ------------------------------------------------------------

  test "suspension revokes API tokens and OAuth grants and blocks the web" do
    app = Doorkeeper::Application.create!(name: "c", redirect_uri: "https://example.com/cb")
    token = Doorkeeper::AccessToken.create!(application: app, resource_owner_id: @owner.id, organization_id: @org.id, scopes: "mcp")
    @org.suspend!(by: nil)

    assert_equal 0, ApiToken.where(organization: @org).count
    assert token.reload.revoked?
    sign_in(@owner)
    get servers_path
    assert_response :forbidden
    assert_match(/suspended/, response.body)
  end

  test "suspension halts jobs at the SSH boundary" do
    @server.update_columns(ownership_verified_at: Time.current)
    @org.suspend!(by: nil)
    conn = SshConnection.new(@server)
    assert_nil conn.execute("echo hi")
    assert_match(/suspended/, conn.error)
  end

  test "admin suspend and reinstate from the admin page" do
    admin = User.create!(email: "root@example.com", admin: true)
    Organization.create_for(admin, name: "ops").update!(onboarded_at: Time.current)
    sign_in(admin)
    post suspend_admin_organization_path(@org)
    assert @org.reload.suspended?
    post reinstate_admin_organization_path(@org)
    assert @org.reload.new_tenant?, "reinstated sign-ups earn trust again"
    assert_equal %w[suspended new], @org.trust_events.order(:id).pluck(:to_level)
  end

  test "a tenant cannot suspend or reinstate" do
    sign_in(@owner)
    post reinstate_admin_organization_path(@org)
    assert @org.reload.new_tenant?
    _, other = signed_up_tenant(email: "victim@example.com")
    post suspend_admin_organization_path(other)
    refute other.reload.suspended?
  end
end
