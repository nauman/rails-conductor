require "test_helper"

class GithubAppTest < ActiveSupport::TestCase
  def pem = file_fixture("test_github_app.pem").read

  def build(app_id: "123") = GithubApp.new(app_id: app_id, private_key: pem)

  test "app_jwt signs an RS256 token verifiable with the public key" do
    token = build.app_jwt(now: 1_000_000)
    header_b64, payload_b64, sig_b64 = token.split(".")
    pub = OpenSSL::PKey::RSA.new(pem).public_key

    signature = Base64.urlsafe_decode64(sig_b64 + "=" * (-sig_b64.length % 4))
    assert pub.verify(OpenSSL::Digest.new("SHA256"), signature, "#{header_b64}.#{payload_b64}"), "signature must verify"

    payload = JSON.parse(Base64.urlsafe_decode64(payload_b64 + "=" * (-payload_b64.length % 4)))
    assert_equal "123", payload["iss"]
    assert_equal 1_000_540, payload["exp"]
  end

  test "raises a friendly error for an invalid private key" do
    bad = GithubApp.new(app_id: "1", private_key: "not a key")
    assert_raises(GithubApp::Error) { bad.app_jwt }
  end

  test "from_config reads the global github_app credential" do
    assert_nil GithubApp.from_config
    Credential.create!(provider: "github_app", name: "GitHub App", organization: nil, api_key: "123", api_secret: pem, active: true)

    gh = GithubApp.from_config
    assert gh.is_a?(GithubApp)
    assert gh.app_jwt.present?
  end

  test "clone_token_for resolves the installation then mints a token" do
    gh = build
    # stub the two API calls
    gh.define_singleton_method(:installation_id_for) { |repo| (@seen ||= []) << repo; 99 }
    gh.define_singleton_method(:installation_token) { |id| "ghs_token_for_#{id}" }

    assert_equal "ghs_token_for_99", gh.clone_token_for("intellectaco/kuickr")
  end
end
