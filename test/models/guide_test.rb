require "test_helper"

class GuideTest < ActiveSupport::TestCase
  test "loads guides from docs/guides, ordered, with frontmatter" do
    guides = Guide.all
    assert guides.any?, "expected guides to load from docs/guides"
    slugs = guides.map(&:slug)
    assert_includes slugs, "connect-github"
    # ordered by frontmatter `order` (getting-started is order 1)
    assert_equal "getting-started", guides.first.slug
    assert guides.first.title.present?
  end

  test "find renders GFM markdown (headings, fenced code, tables) to html" do
    g = Guide.find("connect-github")
    assert g
    html = g.html
    assert_includes html, "<h1"
    assert_includes html, "<pre>" # fenced code block
  end

  test "find rejects path traversal and unknown slugs" do
    assert_nil Guide.find("../../config/database")
    assert_nil Guide.find("nope-not-real")
    assert_nil Guide.find("")
  end
end
