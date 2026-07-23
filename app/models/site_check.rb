# One HTTP timing sample for an app's public URL — the automated version of the
# `curl -w` diagnosis (DNS/TCP/TLS/TTFB/total + status). A time series of these
# drives the site latency/uptime monitor: sparkline, Up/Slow/Down status, and a
# breakdown that shows *what's* slow (high connect/tls = network/distance → CDN;
# high server time = the app).
class SiteCheck < ApplicationRecord
  belongs_to :app

  # A page slower than this (time-to-first-byte) is "slow" even if it's up.
  SLOW_TTFB_MS = 1500

  scope :recent, -> { order(checked_at: :desc) }

  def slow? = up && ttfb_ms.to_i > SLOW_TTFB_MS

  # Up/Slow/Down for badges + rollups.
  def status
    return :down unless up
    slow? ? :slow : :up
  end

  # The server's own time, network stripped out (TTFB minus the TLS/connect setup).
  # High here = the app is slow; low here with a high total = network/distance.
  def server_ms
    [ ttfb_ms.to_i - tls_ms.to_i, 0 ].max
  end
end
