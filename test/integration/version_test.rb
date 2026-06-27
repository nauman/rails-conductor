require "test_helper"

# /version is a public build-info endpoint exposing the running release's git sha
# (kamal injects it as KAMAL_VERSION), so a deploy can be verified externally by
# comparing it to origin/main's HEAD. No auth, no secrets.
class VersionTest < ActionDispatch::IntegrationTest
  test "GET /version returns app + version as JSON without auth" do
    get "/version"

    assert_response :success
    body = JSON.parse(@response.body)
    assert_equal "conductor", body["app"]
    assert body.key?("version")
    assert body.key?("env")
  end

  test "version reflects KAMAL_VERSION when set" do
    original = ENV["KAMAL_VERSION"]
    ENV["KAMAL_VERSION"] = "abc123def"
    get "/version"
    assert_equal "abc123def", JSON.parse(@response.body)["version"]
  ensure
    original.nil? ? ENV.delete("KAMAL_VERSION") : ENV["KAMAL_VERSION"] = original
  end

  test "version is 'unknown' when KAMAL_VERSION is unset" do
    original = ENV["KAMAL_VERSION"]
    ENV.delete("KAMAL_VERSION")
    get "/version"
    assert_equal "unknown", JSON.parse(@response.body)["version"]
  ensure
    ENV["KAMAL_VERSION"] = original unless original.nil?
  end
end
