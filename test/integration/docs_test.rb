require "test_helper"

class DocsTest < ActionDispatch::IntegrationTest
  HUB = "https://kuickr.co/conductor/docs/00-index.md".freeze

  test "the docs index 301-redirects to the kuickr hub (public, no auth)" do
    get "/docs"
    assert_response :moved_permanently
    assert_redirected_to HUB
  end

  test "a guide slug 301-redirects to the kuickr hub too (no in-app copy to drift)" do
    get "/docs/connect-github"
    assert_response :moved_permanently
    assert_redirected_to HUB
  end

  test "even an unknown slug redirects rather than 404 (docs live on kuickr now)" do
    get "/docs/does-not-exist"
    assert_response :moved_permanently
    assert_redirected_to HUB
  end
end
