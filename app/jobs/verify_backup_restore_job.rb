# Proves a backup restores, out of band.
#
# A restore downloads the dump and starts a postgres container, so it must never
# sit on a request. Same stored-result pattern as the other checks: the job pays
# the cost, `verification_status` reads it.
class VerifyBackupRestoreJob < ApplicationJob
  queue_as :ops

  def perform(backup_id)
    backup = Backup.find_by(id: backup_id)
    return unless backup&.enabled?

    result = BackupRestoreVerifier.new(backup).verify!
    Rails.logger.info("[RestoreVerify:#{backup.id}] #{result.status} — #{result.detail}")
    result
  end

  # Verify the STALEST backup, one per night.
  #
  # One, not all: each restore downloads a full dump and runs a postgres
  # container, and doing ten at once on a shared box is the same stampede shape
  # that took the backups down on 08-01. Ordering by verified_at (nulls first)
  # means a fleet of ten is fully covered in ten nights and then rotates, and a
  # never-tested backup always goes before a re-check.
  def self.sweep(organization = nil)
    scope = Backup.enabled.where.not(credential_id: nil)
    scope = scope.where(organization: organization) if organization

    backup = scope.order(Arel.sql("verified_at ASC NULLS FIRST")).first
    return nil if backup.nil?

    perform_later(backup.id)
    backup
  end
end
