# Runs ReleaseDriftDetector out of band and persists the result on the app.
#
# Same reasoning as ResidueCheckJob: the detector makes an SSH round-trip, so it
# must never sit on a request or inside a deploy. The job pays the cost; the
# fast paths read the stored rollup.
class ReleaseDriftCheckJob < ApplicationJob
  queue_as :default

  # A stored result nobody has refreshed in this long should be presented as
  # stale rather than as current truth — which is the very habit this check
  # exists to break.
  STALE_AFTER = 12.hours

  def perform(app_id)
    app = App.find_by(id: app_id)
    return unless app&.server

    store(app, ReleaseDriftDetector.new(app).result)
  rescue StandardError => e
    # A diagnostic that fails must not leave the app looking verified.
    store(app, ReleaseDriftDetector::Result.new(
      status: "unknown",
      detail: "release check failed: #{e.message}",
      remedy: "re-run once the box is reachable — this is NOT a clean result"
    )) if app
  end

  def self.sweep(organization = nil)
    scope = App.where.not(server_id: nil).where.not(deploy_method: "native")
    scope = scope.where(organization: organization) if organization
    scope.find_each { |app| perform_later(app.id) }
  end

  private

  def store(app, result)
    app.update_columns(
      release_state: {
        "status" => result.status,
        "recorded_sha" => result.recorded_sha,
        "running_sha" => result.running_sha,
        "detail" => result.detail,
        "remedy" => result.remedy
      }.compact,
      release_checked_at: Time.current
    )
  end
end
