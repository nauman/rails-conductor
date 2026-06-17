require "test_helper"

class DocsTest < ActionDispatch::IntegrationTest
  test "the docs index is public and lists guides" do
    get "/docs"
    assert_response :success
    assert_match "Conductor docs", @response.body
    assert_match "Connect GitHub", @response.body
  end

  test "a guide page renders the markdown publicly (no auth)" do
    get "/docs/connect-github"
    assert_response :success
    assert_match "Connect GitHub", @response.body
    assert_match "GitHub App", @response.body
  end

  test "an unknown guide returns 404" do
    get "/docs/does-not-exist"
    assert_response :not_found
  end
end
