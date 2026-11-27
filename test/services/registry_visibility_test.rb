require "test_helper"

# What can an ANONYMOUS caller see? That is a different question from
# RegistryImage's "is this built?", and it must be asked without the app's
# credential — a probe that authenticates can only ever answer "yes, I can see
# it", which is not the question.
class RegistryVisibilityTest < ActiveSupport::TestCase
  CODES = {
    Net::HTTPOK => "200", Net::HTTPUnauthorized => "401", Net::HTTPForbidden => "403",
    Net::HTTPNotFound => "404", Net::HTTPInternalServerError => "500"
  }.freeze

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

  # Answers every token request, then defers to `tags` for the tags/list call so
  # each test states only what it is about: what the registry says about a repo.
  def http_where(tags:)
    FakeHttp.new do |req, _host|
      if req.path.start_with?("/token")
        res(Net::HTTPOK, { "token" => "anon" })
      else
        repo = req.path[%r{/v2/(.+)/tags/list}, 1]
        res(tags.call(repo))
      end
    end
  end

  setup do
    user = User.create!(email: "rv@example.com")
    @org = Organization.create_for(user, name: "RV")
    server = @org.servers.create!(name: "box", status: "online", ip_address: "203.0.113.30")
    @app = @org.apps.create!(name: "Vis App", slug: "vis-app", server: server, deploy_method: "kamal")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_SERVER", value: "docker.io")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_USERNAME", value: "amember")
    @app.env_variables.create!(key: "KAMAL_REGISTRY_PASSWORD", value: "dckr_secret", secret: true)
  end

  # The leak this exists to catch: the repository the deploy pushes to is readable
  # by anyone, so the image — and the source inside it — is published.
  test "a repository an anonymous caller can list is public" do
    http = http_where(tags: ->(_repo) { Net::HTTPOK })

    result = RegistryVisibility.new(@app, http: http).check

    assert result.public?, result.detail
    assert_equal "amember/vis-app", result.repository
  end

  # 404 and 401 are the SAME answer here (private, or never pushed), and neither is
  # a reason to block. Only a positive read is.
  test "a refused repository is not public" do
    [ Net::HTTPUnauthorized, Net::HTTPForbidden, Net::HTTPNotFound ].each do |code|
      http = http_where(tags: ->(repo) { repo.start_with?("amember/") ? code : Net::HTTPOK })

      result = RegistryVisibility.new(@app, http: http).check

      refute result.public?, "#{code} must not read as public"
      refute result.unknown?, "#{code} with a working control is a definite answer: #{result.detail}"
    end
  end

  # THE BLINDNESS GUARD. A probe that cannot see ANYTHING returns "refused" for
  # every repository, which would otherwise read as "not public" — a silent
  # fail-open, and exactly the failure that let a public image ship. So the probe
  # proves it can still recognise a public repository before it clears one.
  test "a probe that cannot even see a known-public repository answers unknown, not private" do
    http = http_where(tags: ->(_repo) { Net::HTTPUnauthorized })

    result = RegistryVisibility.new(@app, http: http).check

    assert result.unknown?, "a blind probe must not clear the app: #{result.detail}"
    refute result.public?
    assert_match(/control/i, result.detail)
  end

  test "the control repository is not consulted when the app's own repository reads public" do
    http = http_where(tags: ->(_repo) { Net::HTTPOK })

    RegistryVisibility.new(@app, http: http).check

    tags_calls = http.requested.select { |u| u.include?("/tags/list") }
    assert_equal 1, tags_calls.size, "a positive read needs no control: #{http.requested.inspect}"
  end

  test "an unreachable registry is unknown and never raises into the deploy" do
    exploding = Object.new
    def exploding.start(*, **) = raise(Errno::ECONNREFUSED)

    result = RegistryVisibility.new(@app, http: exploding).check

    assert result.unknown?
    refute result.public?
    assert_match(/unreachable/i, result.detail)
  end

  test "an unexpected status is unknown rather than either answer" do
    http = http_where(tags: ->(_repo) { Net::HTTPInternalServerError })

    result = RegistryVisibility.new(@app, http: http).check

    assert result.unknown?, result.detail
    assert_includes result.detail, "500"
  end

  # The whole point of the namespace split: the image lives in the org, the login
  # is a member's. Probing the login's namespace would ask about the wrong repo.
  test "the probed repository is the one the deploy pushes to, namespace and all" do
    @app.env_variables.create!(key: "KAMAL_IMAGE_NAMESPACE", value: "anorg")
    http = http_where(tags: ->(_repo) { Net::HTTPUnauthorized })

    result = RegistryVisibility.new(@app, http: http).check

    assert_equal "anorg/vis-app", result.repository
    assert http.requested.any? { |u| u.include?("/v2/anorg/vis-app/tags/list") }, http.requested.inspect
  end

  # Asking as the app would defeat the question: the credential can read a private
  # repository, so an authenticated 200 says nothing about what the world sees.
  test "the probe is anonymous — the app's registry credential is never sent" do
    seen = []
    http = FakeHttp.new do |req, _host|
      seen << req["Authorization"]
      req.path.start_with?("/token") ? res(Net::HTTPOK, { "token" => "anon" }) : res(Net::HTTPOK)
    end

    RegistryVisibility.new(@app, http: http).check

    refute seen.compact.any? { |h| h.start_with?("Basic ") },
      "no request may carry the registry credential, got: #{seen.inspect}"
  end

  test "docker hub is probed on its own api host and token service" do
    http = http_where(tags: ->(_repo) { Net::HTTPOK })

    RegistryVisibility.new(@app, http: http).check

    assert http.requested.any? { |u| u.start_with?("auth.docker.io") }, http.requested.inspect
    assert http.requested.any? { |u| u.start_with?("registry-1.docker.io") }, http.requested.inspect
  end

  test "ghcr is probed on its own host" do
    @app.env_variables.find_by(key: "KAMAL_REGISTRY_SERVER").update!(value: "ghcr.io")
    http = http_where(tags: ->(_repo) { Net::HTTPOK })

    result = RegistryVisibility.new(@app, http: http).check

    assert_equal "ghcr.io", result.registry
    assert http.requested.any? { |u| u.start_with?("ghcr.io") }, http.requested.inspect
  end

  # A registry Conductor has no control repository for cannot be cleared OR
  # accused: without a control there is no way to tell a private repo from a
  # blind probe, and guessing either way is the bug.
  test "a registry with no known control repository is unknown when the repo is refused" do
    @app.env_variables.find_by(key: "KAMAL_REGISTRY_SERVER").update!(value: "registry.example.test")
    http = http_where(tags: ->(_repo) { Net::HTTPUnauthorized })

    result = RegistryVisibility.new(@app, http: http).check

    assert result.unknown?, result.detail
    assert_match(/control/i, result.detail)
  end

  # Still a real leak on an unknown registry: a positive read needs no control.
  test "a public repository on an unknown registry is still public" do
    @app.env_variables.find_by(key: "KAMAL_REGISTRY_SERVER").update!(value: "registry.example.test")
    http = http_where(tags: ->(_repo) { Net::HTTPOK })

    result = RegistryVisibility.new(@app, http: http).check

    assert result.public?, result.detail
  end
end
