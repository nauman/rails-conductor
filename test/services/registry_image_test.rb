require "test_helper"

class RegistryImageTest < ActiveSupport::TestCase
  CODES = { Net::HTTPOK => "200", Net::HTTPForbidden => "403", Net::HTTPNotFound => "404" }.freeze

  def res(klass, body = nil)
    response = klass.new("1.1", CODES.fetch(klass), klass.name)
    response.define_singleton_method(:body) { body.to_json }
    response
  end

  class FakeHttp
    attr_reader :requested

    def initialize(&responder) = (@responder, @requested = responder, [])
    def start(host, _port, **) = yield(Session.new(host, @responder, @requested))

    Session = Struct.new(:host, :responder, :requested) do
      def request(req)
        requested << "#{host}#{req.path}"
        responder.call(req, host)
      end
    end
  end

  setup do
    user = User.create!(email: "ri@example.com")
    @org = Organization.create_for(user, name: "RI")
    server = @org.servers.create!(name: "box", status: "online", ip_address: "203.0.113.20")
    @app = @org.apps.create!(name: "Reg App", slug: "reg-app", server: server, deploy_method: "kamal",
                             image_name: "regapp/regapp")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_SERVER", value: "ghcr.io")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_USERNAME", value: "acme")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_PASSWORD", value: "ghp_secret", secret: true)
  end

  # The bug this pins: image_name is stored as "regapp/regapp" while the registry
  # namespace is the account. Querying the stored value asks about a repository that
  # does not exist and gets 401/403 — which reads as "not built", so every build runs
  # and nobody notices the lookup is useless.
  test "the repository path uses the registry account, not the stored image namespace" do
    http = FakeHttp.new { |_req, host| host == "ghcr.io" ? res(Net::HTTPOK, { "token" => "t" }) : res(Net::HTTPOK) }

    result = RegistryImage.new(@app, http: http).check("abc123")

    assert result.exists?
    assert_equal "acme/reg-app".sub("reg-app", "regapp"), result.reference.split(":").first
    assert http.requested.any? { |u| u.include?("/v2/acme/regapp/manifests/abc123") },
      "must query acme/regapp, got: #{http.requested.inspect}"
  end

  test "a private image is checked with the app's own registry credential" do
    seen_auth = nil
    http = FakeHttp.new do |req, host|
      if host == "ghcr.io" && req.path.start_with?("/token")
        seen_auth = req["Authorization"]
        res(Net::HTTPOK, { "token" => "scoped-token" })
      else
        res(Net::HTTPOK)
      end
    end

    RegistryImage.new(@app, http: http).check("abc123")

    assert seen_auth&.start_with?("Basic "), "the token endpoint must receive the registry credential"
  end

  # Asymmetric errors: a false yes rolls a tag that does not exist and takes the app
  # down; a false no costs one build. So anything short of a confirmed manifest is no.
  test "an unauthorised or missing manifest reads as not built, never as built" do
    [ Net::HTTPForbidden, Net::HTTPNotFound ].each do |code|
      http = FakeHttp.new { |req, host| req.path.start_with?("/token") ? res(Net::HTTPOK, { "token" => "t" }) : res(code) }

      result = RegistryImage.new(@app, http: http).check("abc123")

      refute result.exists?, "#{code} must not be treated as built"
      assert_includes result.detail, code.name[/\d+/] || "40"
    end
  end

  test "a registry that raises is not built, and never raises into the deploy" do
    exploding = Object.new
    def exploding.start(*, **) = raise(Errno::ECONNREFUSED)

    result = RegistryImage.new(@app, http: exploding).check("abc123")

    refute result.exists?
    assert_includes result.detail, "unreachable"
  end

  test "docker hub uses its own api host and token service" do
    @app.env_variables.find_by(key: "KAMAL_REGISTRY_SERVER").update!(value: "docker.io")
    http = FakeHttp.new { |req, _host| req.path.start_with?("/token") ? res(Net::HTTPOK, { "token" => "t" }) : res(Net::HTTPOK) }

    RegistryImage.new(@app, http: http).check("abc123")

    assert http.requested.any? { |u| u.start_with?("auth.docker.io") }, http.requested.inspect
    assert http.requested.any? { |u| u.start_with?("registry-1.docker.io") }, http.requested.inspect
  end
end
