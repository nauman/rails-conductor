# Audits a fleet app's Active Storage over SSH: where its blobs actually live
# (service_name distribution), which service the app is configured to use, is
# that service reachable, and how many blobs are NOT on the configured service
# (the "at risk" count — e.g. blobs still on local Disk after a host migration).
# Read-only. Runs a rails runner in the app's container via RemoteRailsRunner.
class ActiveStorageAuditor
  Result = Struct.new(:ok, :data, :error, keyword_init: true) do
    def ok? = ok
  end

  # Container-side Ruby (literal — single-quoted heredoc). __MARKER__ is swapped
  # for the runner's marker at build time.
  BODY = <<~'RUBY'
    require "json"
    dist = ActiveStorage::Blob.group(:service_name).count
    configured = Rails.application.config.active_storage.service.to_s
    reachable = begin
      ActiveStorage::Blob.services.fetch(configured.to_sym).exist?("__conductor_reachability_probe__")
      true
    rescue => _e
      false
    end
    at_risk = dist.reject { |k, _| k.to_s == configured }.values.sum
    puts "__MARKER__" + {
      total_blobs: dist.values.sum,
      service_distribution: dist,
      configured_service: configured,
      storage_reachable: reachable,
      blobs_not_on_configured_service: at_risk
    }.to_json
  RUBY

  def initialize(app, runner: nil)
    @app = app
    @runner = runner || RemoteRailsRunner.new(app)
  end

  def script = BODY.sub("__MARKER__", RemoteRailsRunner::MARKER)

  def call
    res = @runner.run(script)
    payload = res.payload
    return Result.new(ok: true, data: payload) if payload

    Result.new(ok: false, error: audit_error(res))
  end

  private

  def audit_error(res)
    return "No running container found for #{@app.name} on #{@app.server&.name}." if res.output.to_s.include?("NO_CONTAINER")
    "Active Storage audit failed: #{res.output.to_s.lines.last(3).join.strip.presence || 'no output'}"
  end
end
