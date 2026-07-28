require "test_helper"

class GithubClientWebhookTest < ActiveSupport::TestCase
  # Stub Faraday connection: canned responses shifted in call order.
  class FakeConn
    Resp = Struct.new(:status, :body) { def success? = status.between?(200, 299) }
    Req = Struct.new(:body)
    attr_reader :calls
    def initialize(responses) = (@responses = responses; @calls = [])
    def get(path) = record(:get, path)
    def delete(path) = record(:delete, path)
    def post(path) = (req = Req.new; yield req if block_given?; record(:post, path, req.body))
    def record(verb, path, body = nil) = (@calls << [ verb, path, body ]; @responses.shift)
  end

  def client_with(conn)
    c = GithubClient.new("tok")
    c.instance_variable_set(:@conn, conn)
    c
  end

  URL = "https://conductor.example.com/webhooks/github/15".freeze

  test "create_webhook posts a push hook and returns it" do
    conn = FakeConn.new([ FakeConn::Resp.new(200, "[]"), FakeConn::Resp.new(201, '{"id":99}') ])
    hook = client_with(conn).create_webhook(repo: "railslink/railslink", url: URL, secret: "s3cr3t")
    assert_equal 99, hook["id"]
    post = conn.calls.find { |verb,| verb == :post }
    assert_equal "/repos/railslink/railslink/hooks", post[1]
    assert_includes post[2], '"events":["push"]'
    assert_includes post[2], URL
    assert_includes post[2], "s3cr3t"
    assert_includes post[2], '"content_type":"json"'
  end

  test "create_webhook replaces an existing hook with the same url (idempotent)" do
    conn = FakeConn.new([
      FakeConn::Resp.new(200, %([{"id":7,"config":{"url":"#{URL}"}}])), # list -> exists
      FakeConn::Resp.new(204, ""),                                      # delete
      FakeConn::Resp.new(201, '{"id":100}')                            # create
    ])
    client_with(conn).create_webhook(repo: "r/r", url: URL, secret: "x")
    assert conn.calls.any? { |verb, path, _| verb == :delete && path == "/repos/r/r/hooks/7" }
  end
end

class GithubWebhookInstallerTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "ghwh@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Appone", slug: "appone", deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/appone.git")
  end

  class FakeClient
    attr_reader :created
    def create_webhook(**kwargs) = (@created = kwargs; { "id" => 55 })
  end

  test "installs the push webhook pointing at Conductor with the app's secret" do
    @org.credentials.create!(provider: "github", name: "GitHub", api_key: "ghp_x", active: true)
    client = FakeClient.new
    result = GithubWebhookInstaller.install(@app, client: client, host: "conductor.test")
    assert result[:installed]
    assert_equal "pavelabs/appone", result[:repo]
    assert_equal "https://conductor.test#{@app.webhook_path}", result[:webhook_url]
    assert_equal @app.webhook_secret, client.created[:secret]
    assert_equal result[:webhook_url], client.created[:url]
  end

  test "no-ops with a reason when the org has no GitHub token" do
    result = GithubWebhookInstaller.install(@app, client: FakeClient.new, host: "conductor.test")
    refute result[:installed]
    assert_includes result[:reason], "No GitHub token"
  end

  test "no-ops when the repo can't be parsed" do
    @org.credentials.create!(provider: "github", name: "GitHub", api_key: "ghp_x", active: true)
    @app.update_column(:repository_url, "not-a-github-url")
    result = GithubWebhookInstaller.install(@app, client: FakeClient.new, host: "conductor.test")
    refute result[:installed]
    assert_includes result[:reason], "Could not parse"
  end

  test "reports GitHub API errors without raising" do
    @org.credentials.create!(provider: "github", name: "GitHub", api_key: "ghp_x", active: true)
    failing = Object.new
    def failing.create_webhook(**) = raise(GithubClient::Error, "GitHub API 404: not found")
    result = GithubWebhookInstaller.install(@app, client: failing, host: "conductor.test")
    refute result[:installed]
    assert_includes result[:reason], "404"
  end
end
