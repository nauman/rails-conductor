require "open3"

# Curl-times an app's public URL and records a SiteCheck — the automated version of
# the manual `curl -w` diagnosis. One lean HTTP GET (follows redirects), capturing
# the DNS/TCP/TLS/TTFB/total breakdown + status. Read-only against the app's site.
class SiteMonitor
  # Order matches parse() below.
  FORMAT = "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}".freeze
  TIMEOUT = 20

  def initialize(app, runner: nil)
    @app = app
    @runner = runner || method(:curl) # injectable for tests
  end

  # Runs the check and persists a SiteCheck. Returns it, or nil if the app has no URL.
  def check!
    return nil if @app.url.blank?

    @app.site_checks.create!(parse(@runner.call(@app.url)).merge(checked_at: Time.current))
  end

  private

  def curl(url)
    out, = Open3.capture2e("curl", "-sSL", "-o", "/dev/null", "--max-time", TIMEOUT.to_s, "-w", FORMAT, url)
    out
  end

  def parse(raw)
    code, dns, conn, tls, ttfb, total = raw.to_s.strip.split
    status = code.to_i
    up = status >= 200 && status < 400

    {
      up: up,
      status_code: status.zero? ? nil : status,
      dns_ms: ms(dns), connect_ms: ms(conn), tls_ms: ms(tls),
      ttfb_ms: ms(ttfb), total_ms: ms(total),
      error: up ? nil : (status.zero? ? "no response (timeout / connection failed)" : "HTTP #{status}")
    }
  end

  def ms(seconds) = (seconds.to_f * 1000).round
end
