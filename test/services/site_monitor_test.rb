require "test_helper"

class SiteMonitorTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "sm@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Site", slug: "site", deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "example.com")
  end

  # curl -w output: code dns connect appconnect starttransfer total (seconds)
  def run_with(output) = SiteMonitor.new(@app, runner: ->(_url) { output }).check!

  test "records a healthy check with the timing breakdown in ms" do
    c = run_with("200 0.002 0.320 0.650 0.970 1.100")
    assert c.up
    assert_equal 200, c.status_code
    assert_equal :up, c.status
    assert_equal 320, c.connect_ms   # TCP RTT
    assert_equal 650, c.tls_ms
    assert_equal 970, c.ttfb_ms
    assert_equal 1100, c.total_ms
    assert_nil c.error
    assert c.checked_at.present?
  end

  test "detects a Cloudflare-fronted response from headers (via_cdn)" do
    headers = "HTTP/2 200\r\nserver: cloudflare\r\ncf-ray: a1fb-SYD\r\n\r\n"
    c = SiteMonitor.new(@app, runner: ->(_url) { "#{headers}\n200 0.002 0.020 0.040 0.100 0.150" }).check!
    assert c.up
    assert c.via_cdn, "expected via_cdn when cf-ray/server:cloudflare present"
    assert @app.reload.behind_cdn?
  end

  test "a plain-origin response (no CDN headers) is not via_cdn" do
    refute run_with("200 0.002 0.320 0.650 0.970 1.100").via_cdn
  end

  test "a fast 200 under the slow threshold is :up, a slow one is :slow" do
    assert_equal :up,   run_with("200 0 0.1 0.2 0.3 0.4").status
    assert_equal :slow, run_with("200 0 0.3 0.6 2.5 3.0").status # ttfb 2500ms > 1500
  end

  test "a connection failure (code 000) records down with a clear error" do
    c = run_with("000 0 0 0 0 0")
    refute c.up
    assert_nil c.status_code
    assert_equal :down, c.status
    assert_match(/timeout|connection/i, c.error)
  end

  test "an HTTP error (5xx) is down" do
    c = run_with("503 0.002 0.3 0.6 0.9 0.9")
    refute c.up
    assert_equal :down, c.status
    assert_match(/503/, c.error)
  end

  test "server_ms strips the TLS/setup so you can see app vs network" do
    c = run_with("200 0 0.3 0.6 0.65 0.7") # ttfb 650, tls 600 → server ~50ms (network-bound)
    assert_equal 50, c.server_ms
  end

  test "no URL (no domain) is a no-op" do
    @app.update!(domain: nil)
    assert_nil SiteMonitor.new(@app, runner: ->(_) { "200 0 0 0 0 0" }).check!
  end
end
