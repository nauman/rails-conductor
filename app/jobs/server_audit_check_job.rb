# Keeps each server's security grade current.
#
# `Server#audit_fresh?(within: 7.days)` already existed, and DeployPreflight
# already used it well — a stale `secure` degrades to a warning rather than
# clearing a deploy. The logic was never the gap.
#
# The gap was that nothing ever made an audit fresh again except a human running
# one, so freshness could only ever decay. A server's grade sat five weeks old
# while the preflight gated deploys on it, and both directions were wrong: an
# `at_risk` from July blocks a box that may since have been fixed, and a `secure`
# from July clears one that may since have rotted.
#
# Same stored-rollup pattern as ResidueCheckJob and ReleaseDriftCheckJob (ADR 0010):
# the job pays the SSH cost out of band, the fast paths read what was stored.
class ServerAuditCheckJob < ApplicationJob
  queue_as :ops

  # `auditor:` is injectable so a test can drive the outcomes without a box.
  def perform(server_id, auditor: nil)
    server = Server.find_by(id: server_id)
    return unless server

    result = (auditor || ServerAudit.new(server)).audit

    # FAIL TOWARD STALE, NEVER TOWARD A BETTER GRADE. An unreachable box is not a
    # box that became secure, and this runs unattended — so a failed probe leaves
    # the previous grade AND the previous timestamp alone, and the existing
    # freshness check turns that silence into a visible warning by itself.
    unless result.respond_to?(:ok?) && result.ok? && result.status.present?
      detail = result.respond_to?(:error) ? result.error : "no result"
      Rails.logger.warn "[ServerAudit] #{server.name}: audit did not complete — #{detail}"
      return
    end

    previous = server.last_audit_status
    server.record_audit!(result.status)
    return if previous == result.status.to_s

    Rails.logger.info "[ServerAudit] #{server.name}: #{previous.presence || 'never'} -> #{result.status}"
  rescue StandardError => e
    # A diagnostic job that raises must not look like a clean audit.
    Rails.logger.warn "[ServerAudit] #{server&.name}: #{e.class}: #{e.message}"
  end

  # Read-only over SSH, so safe to run often. Daily is well inside the 7-day
  # freshness window, leaving room for a box to be unreachable for several days
  # before its grade goes stale.
  def self.sweep(organization = nil)
    scope = Server.all
    scope = scope.where(organization: organization) if organization
    scope.find_each { |server| perform_later(server.id) }
  end
end
