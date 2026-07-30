# Finalizes self-managed (Conductor-deploys-itself) deployments that couldn't be
# observed inline. When Conductor deploys its own app, `kamal deploy` boots the
# new release and stops the old container — the one running DeployAppJob — so the
# job is SIGTERM'd before it reaches `deployment.succeed!`. The new container runs
# this on boot: kamal injects the deployed git sha as KAMAL_VERSION, so a match
# against an in-progress deployment's commit_sha means that deploy is now live.
#
#   - match (running version == deployment's sha) → succeed!
#   - stale (in progress past STALE_AFTER, no match) → fail! (the release that
#     would have matched never came up)
#   - recent + no match → leave it (genuinely still building/deploying)
class SelfDeployReconciler
  STALE_AFTER = 20.minutes

  def self.run(version: App.current_release_version)
    new(version).run
  end

  def initialize(version)
    @version = version.to_s
  end

  def run
    return if @version.blank?

    # A deployment whose commit_sha is the sha THIS container runs is, by
    # definition, an app deploying ITSELF: the release swap that SIGTERM'd the
    # deploy job is the one that booted this very container. Detect self-deploys
    # that way — no hard-coded app id — finalize them, and SELF-HEAL the
    # self_managed flag so the DeployAppJob re-entry guard and future boot
    # reconciles both apply. This is exactly what was missing when Conductor's own
    # app sat at self_managed:false and every self-deploy looped + emailed a false
    # failure: nothing recognized it as a self-deploy. A non-self app deployed FROM
    # Conductor records ITS repo's sha, never this container's, so it never matches.
    Deployment.in_progress.includes(:app).find_each do |deployment|
      next unless version_matches?(deployment.commit_sha)

      deployment.app.update!(self_managed: true) unless deployment.app.self_managed?
      deployment.append_log("Self-deploy reconciled: release #{short(@version)} is live; marking succeeded.")
      deployment.succeed!
    end

    # A self-managed deployment still in progress that did NOT match a live release
    # and is past the window never completed (the release that would have matched
    # never came up) — fail it so it can't hang forever.
    App.self_managed.find_each do |app|
      app.deployments.in_progress.each do |deployment|
        next if version_matches?(deployment.commit_sha)
        next unless stale?(deployment)

        deployment.fail!("Self-deploy did not complete: the container was replaced and no matching live release (#{short(@version)}) appeared within #{STALE_AFTER.inspect}.")
      end
    end
  end

  private

  # kamal's version may be a short sha while we record the full one (or vice
  # versa), so accept a prefix match in either direction.
  def version_matches?(sha)
    return false if sha.blank?
    a = sha.to_s
    @version.start_with?(a) || a.start_with?(@version)
  end

  def stale?(deployment)
    deployment.started_at.present? && deployment.started_at < STALE_AFTER.ago
  end

  def short(sha) = sha.to_s[0, 12]
end
