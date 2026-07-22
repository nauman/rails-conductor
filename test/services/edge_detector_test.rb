require "test_helper"

class EdgeDetectorTest < ActiveSupport::TestCase
  test "host Caddy edge is detected and an inert kamal-proxy is flagged" do
    out = <<~OUT
      KAMAL_PROXY:basecamp/kamal-proxy:v0.9.2
      KAMAL_PROXY_STATE:created
      CADDY:yes
      CADDY_ADMIN:200
      PORT80:1
      PORT443:1
    OUT
    r = EdgeDetector.classify(out)
    assert_equal "caddy", r[:edge_type]
    assert_match(/Admin API/, r[:edge_detail])
    assert_match(/inert kamal-proxy/, r[:edge_detail], "should warn about the exact platepose trap")
  end

  test "a running kamal-proxy with no Caddy is kamal_proxy" do
    out = <<~OUT
      KAMAL_PROXY:basecamp/kamal-proxy:v0.9.2
      KAMAL_PROXY_STATE:running
      CADDY:no
      CADDY_ADMIN:000
      PORT80:1
      PORT443:1
    OUT
    r = EdgeDetector.classify(out)
    assert_equal "kamal_proxy", r[:edge_type]
    assert_match(/kamal-proxy/, r[:edge_detail])
  end

  test "caddy wins even when the admin API isn't reachable" do
    out = "KAMAL_PROXY:\nKAMAL_PROXY_STATE:none\nCADDY:yes\nCADDY_ADMIN:000\nPORT80:1\nPORT443:1\n"
    r = EdgeDetector.classify(out)
    assert_equal "caddy", r[:edge_type]
    refute_match(/Admin API/, r[:edge_detail])
    refute_match(/inert/, r[:edge_detail], "no kamal-proxy present, so no note")
  end

  test "something else on :80/:443 is 'other'" do
    out = "KAMAL_PROXY:\nKAMAL_PROXY_STATE:none\nCADDY:no\nCADDY_ADMIN:000\nPORT80:1\nPORT443:0\n"
    assert_equal "other", EdgeDetector.classify(out)[:edge_type]
  end

  test "nothing listening is 'none'" do
    out = "KAMAL_PROXY:\nKAMAL_PROXY_STATE:none\nCADDY:no\nCADDY_ADMIN:000\nPORT80:0\nPORT443:0\n"
    assert_equal "none", EdgeDetector.classify(out)[:edge_type]
  end

  test "blank output is 'unknown'" do
    assert_equal "unknown", EdgeDetector.classify("")[:edge_type]
  end
end
