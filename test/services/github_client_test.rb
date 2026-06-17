require "test_helper"

class GithubClientTest < ActiveSupport::TestCase
  # Stub Faraday connection capturing requests and returning canned responses.
  class FakeConn
    Resp = Struct.new(:status, :body) { def success? = status.between?(200, 299) }
    attr_reader :calls
    def initialize(responses) = (@responses = responses; @calls = [])
    def get(path) = record(:get, path)
    def delete(path) = record(:delete, path)
    def post(path) = (req = Req.new; yield req if block_given?; record(:post, path, req.body))
    def record(verb, path, body = nil) = (@calls << [verb, path, body]; @responses.shift)
    Req = Struct.new(:body)
  end

  def client_with(conn)
    c = GithubClient.new("tok")
    c.instance_variable_set(:@conn, conn)
    c
  end

  test "add_deploy_key posts the key and returns the created key" do
    conn = FakeConn.new([
      FakeConn::Resp.new(200, "[]"),                       # list (none existing)
      FakeConn::Resp.new(201, '{"id":42,"title":"conductor-kuickr"}') # create
    ])
    c = client_with(conn)

    key = c.add_deploy_key(repo: "pavelabs/kuickr", title: "conductor-kuickr", key: "ssh-ed25519 AAAA", read_only: true)

    assert_equal 42, key["id"]
    post = conn.calls.find { |verb,| verb == :post }
    assert_equal "/repos/pavelabs/kuickr/keys", post[1]
    assert_includes post[2], "ssh-ed25519"
    assert_includes post[2], "\"read_only\":true"
  end

  test "add_deploy_key replaces an existing key with the same title (idempotent)" do
    conn = FakeConn.new([
      FakeConn::Resp.new(200, '[{"id":7,"title":"conductor-kuickr"}]'), # list (exists)
      FakeConn::Resp.new(204, ""),                                       # delete
      FakeConn::Resp.new(201, '{"id":43}')                              # create
    ])
    c = client_with(conn)

    c.add_deploy_key(repo: "pavelabs/kuickr", title: "conductor-kuickr", key: "ssh-ed25519 AAAA")

    assert conn.calls.any? { |verb, path,| verb == :delete && path == "/repos/pavelabs/kuickr/keys/7" }
  end

  test "raises GithubClient::Error on a failed create" do
    conn = FakeConn.new([
      FakeConn::Resp.new(200, "[]"),
      FakeConn::Resp.new(403, '{"message":"Resource not accessible"}')
    ])
    assert_raises(GithubClient::Error) do
      client_with(conn).add_deploy_key(repo: "o/r", title: "t", key: "k")
    end
  end
end
