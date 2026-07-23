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
    # -D - dumps response headers to stdout (so we can detect a CDN in front); the
    # -w metrics line is appended last on its own line for a clean split in parse().
    out, = Open3.capture2e("curl", "-sSL", "-o", "/dev/null", "-D", "-",
                           "--max-time", TIMEOUT.to_s, "-w", "\n#{FORMAT}", url)
    out
  end

  def parse(raw)
    text = raw.to_s
    # Metrics are the last non-empty line (the -w output); anything before it is the
    # response headers (present with real curl, absent in unit stubs).
    metrics = text.lines.map(&:strip).reject(&:empty?).last.to_s
    code, dns, conn, tls, ttfb, total = metrics.split
    status = code.to_i
    up = status >= 200 && status < 400

    {
      up: up,
      status_code: status.zero? ? nil : status,
      dns_ms: ms(dns), connect_ms: ms(conn), tls_ms: ms(tls),
      ttfb_ms: ms(ttfb), total_ms: ms(total),
      via_cdn: cloudflare?(text),
      error: up ? nil : (status.zero? ? "no response (timeout / connection failed)" : "HTTP #{status}")
    }
  end

  # A Cloudflare-proxied response carries a `cf-ray` header and `server: cloudflare`.
  def cloudflare?(text)
    text.match?(/^\s*cf-ray:/i) || text.match?(/^\s*server:\s*cloudflare/i)
  end

  def ms(seconds) = (seconds.to_f * 1000).round
end
