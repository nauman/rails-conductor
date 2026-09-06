require "test_helper"

# Caddy has ONE on-demand permission endpoint per instance and per-zone policies.
# Refusing to re-point it stops one zone silently breaking another — but it also
# means a box genuinely cannot serve two zones' on-demand TLS, because whichever
# app owns the endpoint answers 404 for every name that is not its own.
#
# The way out is an endpoint that knows every zone on the box: Conductor's own,
# answering from the policies it maintains.
class SharedAskEndpointTest < ActionDispatch::IntegrationTest
  setup do
    user = User.create!(email: "sae@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @org.update!(onboarded_at: Time.current)
    @server = @org.servers.create!(name: "edge", status: "online", ip_address: "10.0.0.77")
    @token = @server.ask_token!
    # NB: @subject, not @app — IntegrationTest stores the Rack application in @app,
    # and overwriting it makes every `get` call App#call.
    @subject = @org.apps.create!(name: "appone", slug: "appone", server: @server, deploy_method: "kamal",
                             port: 3000, repository_url: "https://github.com/x/y.git",
                             domain: "zone-a.example")
  end

  # The gate is called by Caddy, unauthenticated, before issuing a certificate.
  # It must answer without a session — a login redirect reads as "refused".
  test "the gate answers a permitted name without authentication" do
    get caddy_ask_path, params: { domain: "sub.zone-a.example", server: @token }

    assert_response :success
  end

  test "a name no app on this fleet claims is refused" do
    get caddy_ask_path, params: { domain: "sub.not-ours.example", server: @token }

    assert_response :not_found
  end

  # The apex itself, not only subdomains.
  test "a registered domain is permitted" do
    get caddy_ask_path, params: { domain: "zone-a.example", server: @token }

    assert_response :success
  end

  # WITHOUT THIS THE GATE IS AN OPEN RELAY. Caddy asks before issuing, so a gate
  # that says yes to everything invites unbounded issuance for any name pointed at
  # the box — a fast route to a Let's Encrypt rate-limit ban that takes the whole
  # fleet's certificates with it.
  test "a missing domain is refused rather than defaulted" do
    get caddy_ask_path, params: { server: @token }

    assert_response :not_found
  end

  test "a name belonging to another organization is refused" do
    other = Organization.create_for(User.create!(email: "other@example.com"), name: "Other")
    srv = other.servers.create!(name: "theirs", status: "online", ip_address: "10.0.0.78")
    other.apps.create!(name: "theirs", slug: "theirs", server: srv, deploy_method: "kamal",
                       port: 3000, repository_url: "https://github.com/x/z.git",
                       domain: "their-zone.example")

    get caddy_ask_path, params: { domain: "sub.their-zone.example", server: @token }

    assert_response :not_found, "this box does not serve that zone"
  end

  # WITHOUT THE TOKEN THE GATE IS AN OPEN RELAY. Caddy sends only the domain, so a
  # gate that answers without knowing which box asked would issue certificates for
  # every zone on the fleet.
  test "an unidentified caller is refused even for a name we do serve" do
    get caddy_ask_path, params: { domain: "sub.zone-a.example" }

    assert_response :not_found
  end

  test "an unrecognised token is refused" do
    get caddy_ask_path, params: { domain: "sub.zone-a.example", server: "not-a-real-token" }

    assert_response :not_found
  end
end
