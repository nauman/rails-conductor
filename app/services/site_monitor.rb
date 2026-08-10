require "open3"

# Curl-times an app's public URL and records a SiteCheck — the automated version of
# the manual `curl -w` diagnosis. One lean HTTP GET (follows redirects), capturing
# the DNS/TCP/TLS/TTFB/total breakdown + status. Read-only against the app's site.
class SiteMonitor
  # Order matches parse() below.
  FORMAT = "%{http_code} %{time_namelookup} %{time_connect} %{time_appconnect} %{time_starttransfer} %{time_total}".freeze
  TIMEOUT = 20

  # A single failed probe is not an outage — a transient timeout once recorded a
  # healthy app as down and left the fleet reading red all day. Confirm any
  # failure with one re-probe before recording it.
  RETRY_DELAY = 1

  # The confirmation probe is deliberately cheaper than the first. MonitorSitesJob
  # sweeps every app SERIALLY every 5 minutes; at the full timeout a dead app cost
  # TIMEOUT + delay + TIMEOUT, so enough dead apps overran the sweep's own
  # schedule and left monitoring incomplete.
  CONFIRM_TIMEOUT = 6

  # A failure that clears on the retry. The check is recorded `up` — the app is
  # serving — but saying so plainly is what keeps a flapping host visible instead
  # of averaging it away into "healthy".
  RECOVERED = "recovered on retry".freeze

  def initialize(app, runner: nil, retry_delay: RETRY_DELAY)
    @app = app
    @runner = runner || method(:curl) # injectable for tests
    @retry_delay = retry_delay
  end

  # Runs the check and persists a SiteCheck. Returns it, or nil if the app has no URL.
  def check!
    return nil if @app.url.blank?

    @app.site_checks.create!(probe.merge(checked_at: Time.current))
  end

  private

  # One probe; on failure, sleep briefly and probe again more cheaply. A blip
  # resolves to `up` but is labelled RECOVERED so a flapping host stays visible;
  # a failure the retry agrees with is recorded as confirmed.
  def probe
    first = parse(probe_once(TIMEOUT))
    return first if first[:up]

    sleep @retry_delay if @retry_delay.to_f.positive?
    confirmation = parse(probe_once(CONFIRM_TIMEOUT))

    if confirmation[:up]
      confirmation.merge(error: "#{RECOVERED} — first probe: #{first[:error]}")
    else
      confirmation.merge(error: "#{confirmation[:error]} (confirmed by a second probe)")
    end
  end

  def probe_once(timeout)
    @runner.call(@app.url, timeout)
  end

  def curl(url, timeout = TIMEOUT)
    # -D - dumps response headers to stdout (so we can detect a CDN in front); the
    # -w metrics line is appended last on its own line for a clean split in parse().
    out, = Open3.capture2e("curl", "-sSL", "-o", "/dev/null", "-D", "-",
                           "--max-time", timeout.to_s, "-w", "\n#{FORMAT}", url)
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
