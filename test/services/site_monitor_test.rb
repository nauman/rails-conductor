require "test_helper"

class SiteMonitorTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "sm@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @app = @org.apps.create!(name: "Site", slug: "site", deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "example.com")
  end

  # curl -w output: code dns connect appconnect starttransfer total (seconds)
  def run_with(output) = SiteMonitor.new(@app, runner: ->(_url, _timeout = nil) { output }).check!

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
    c = SiteMonitor.new(@app, runner: ->(_url, _timeout = nil) { "#{headers}\n200 0.002 0.020 0.040 0.100 0.150" }).check!
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

  # A single timed-out probe is not an outage. On 2026-08-09 one transient
  # timeout recorded Kuickr as down while it served 200 in 0.38s from every
  # vantage point, and the fleet dashboard showed a red app for the rest of the
  # day. A failure must be confirmed by a second probe before it is recorded.
  class ProbeSpy
    attr_reader :calls, :timeouts
    def initialize(*outputs)
      @outputs = outputs
      @calls = 0
      @timeouts = []
    end

    def to_proc = ->(_url, _timeout = nil) { @calls += 1; @timeouts << _timeout; @outputs[[ @calls - 1, @outputs.size - 1 ].min] }
  end

  test "a failed probe that succeeds on retry is recorded as up, not down" do
    spy = ProbeSpy.new("000 0 0 0 0 0", "200 0.002 0.020 0.040 0.100 0.150")
    c = SiteMonitor.new(@app, runner: spy.to_proc, retry_delay: 0).check!

    assert_equal 2, spy.calls, "a failure must trigger exactly one confirming re-probe"
    assert c.up, "the confirming probe succeeded, so the app was never down"
    assert_equal 200, c.status_code
  end

  test "a failure confirmed by the second probe is recorded as down and says so" do
    spy = ProbeSpy.new("000 0 0 0 0 0", "000 0 0 0 0 0")
    c = SiteMonitor.new(@app, runner: spy.to_proc, retry_delay: 0).check!

    assert_equal 2, spy.calls
    refute c.up
    assert_equal :down, c.status
    assert_match(/confirmed by a second probe/, c.error)
  end

  test "a healthy probe is never re-probed" do
    spy = ProbeSpy.new("200 0.002 0.020 0.040 0.100 0.150")
    SiteMonitor.new(@app, runner: spy.to_proc, retry_delay: 0).check!
    assert_equal 1, spy.calls, "a healthy check must cost exactly one request"
  end

  test "an HTTP error status is also confirmed before being recorded" do
    spy = ProbeSpy.new("502 0 0.01 0.02 0.03 0.04", "200 0.002 0.020 0.040 0.100 0.150")
    c = SiteMonitor.new(@app, runner: spy.to_proc, retry_delay: 0).check!
    assert_equal 2, spy.calls
    assert c.up
  end

  # Codex review R-1: recording only the SECOND probe made a flapping host —
  # one sick worker behind a round-robin — record `up` on essentially every
  # sweep, because the retry keeps landing on a healthy path. Suppressing a blip
  # must not also suppress the evidence that the site is unstable.
  test "a failure that recovers on retry is recorded up, but says it recovered" do
    spy = ProbeSpy.new("000 0 0 0 0 0", "200 0.002 0.020 0.040 0.100 0.150")
    c = SiteMonitor.new(@app, runner: spy.to_proc, retry_delay: 0).check!

    assert c.up, "the confirming probe succeeded, so the app is serving"
    assert_match(/recovered on retry/i, c.error.to_s,
      "a recovered failure must stay visible or a flapping site reads as healthy")
    assert c.recovered_on_retry?
  end

  test "a clean check is not marked as recovered" do
    refute run_with("200 0.002 0.020 0.040 0.100 0.150").recovered_on_retry?
  end

  # Codex review R-1 (second half): MonitorSitesJob sweeps every app serially
  # every 5 minutes. At the full 20s curl timeout, one dead app cost 20s + sleep
  # + 20s; enough dead apps and the sweep overruns its own schedule.
  test "the confirming probe uses a shorter timeout than the first" do
    spy = ProbeSpy.new("000 0 0 0 0 0", "000 0 0 0 0 0")
    SiteMonitor.new(@app, runner: spy.to_proc, retry_delay: 0).check!

    assert_equal 2, spy.calls
    assert_equal SiteMonitor::TIMEOUT, spy.timeouts.first
    assert_equal SiteMonitor::CONFIRM_TIMEOUT, spy.timeouts.last
    assert SiteMonitor::CONFIRM_TIMEOUT < SiteMonitor::TIMEOUT,
      "the confirmation must be cheaper, or a fleet of dead apps overruns the sweep"
  end
end
