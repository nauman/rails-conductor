require "pg"
require "uri"

# Reads Solid Queue health for an app by connecting to its queue database
# (Rails 8's default Active Job backend is DB-backed). Read-only and tolerant:
# apps that don't use Solid Queue (tables absent) or unreachable DBs return an
# unavailable Result rather than raising, so the dashboard never breaks.
class SolidQueueStats
  # Solid Queue workers heartbeat ~every 60s; treat a process as dead once its
  # heartbeat is older than this (matches SolidQueue's default alive threshold).
  HEARTBEAT_TTL = 5.minutes
  CONNECT_TIMEOUT = 3

  Result = Data.define(:available, :error, :workers, :pending, :running, :scheduled, :failed) do
    def workers_alive = workers.count { |w| w[:alive] }
    def workers_total = workers.size
    def all_workers_alive? = workers.any? && workers.all? { |w| w[:alive] }
    # Healthy = reachable, workers present and all beating, nothing failed.
    def healthy? = available && error.nil? && all_workers_alive? && failed.zero?
    def degraded? = available && error.nil? && (failed.positive? || !all_workers_alive?)
  end

  def self.for(app) = new(app).call

  def initialize(app)
    @app = app
  end

  def call
    url = database_url
    return unavailable("no database URL configured") unless url

    conn = PG.connect(connection_params(url))
    begin
      return unavailable("Solid Queue not installed") unless table?(conn, "solid_queue_processes")

      Result.new(
        available: true, error: nil,
        workers: workers(conn),
        pending: count(conn, "solid_queue_ready_executions"),
        running: count(conn, "solid_queue_claimed_executions"),
        scheduled: count(conn, "solid_queue_scheduled_executions"),
        failed: count(conn, "solid_queue_failed_executions")
      )
    ensure
      conn.close
    end
  rescue PG::Error, URI::InvalidURIError, ArgumentError => e
    unavailable(e.message.to_s.lines.first&.strip)
  end

  private

  attr_reader :app

  def database_url
    env = app.env_hash
    env["QUEUE_DATABASE_URL"].presence || env["DATABASE_URL"].presence
  end

  def connection_params(url)
    uri = URI.parse(url)
    {
      host: uri.host, port: uri.port || 5432,
      dbname: uri.path.delete_prefix("/").presence,
      user: uri.user, password: uri.password,
      connect_timeout: CONNECT_TIMEOUT
    }.compact
  end

  def table?(conn, name)
    !conn.exec_params("SELECT to_regclass($1)", ["public.#{name}"]).getvalue(0, 0).nil?
  end

  def count(conn, table)
    conn.exec("SELECT count(*) FROM #{table}").getvalue(0, 0).to_i
  rescue PG::Error
    0
  end

  def workers(conn)
    cutoff = Time.current - HEARTBEAT_TTL
    conn.exec("SELECT name, kind, last_heartbeat_at FROM solid_queue_processes ORDER BY kind, name").map do |row|
      hb = row["last_heartbeat_at"] ? Time.zone.parse(row["last_heartbeat_at"]) : nil
      { name: row["name"], kind: row["kind"], last_heartbeat_at: hb, alive: hb.present? && hb > cutoff }
    end
  end

  def unavailable(message)
    Result.new(available: false, error: message, workers: [], pending: 0, running: 0, scheduled: 0, failed: 0)
  end
end
