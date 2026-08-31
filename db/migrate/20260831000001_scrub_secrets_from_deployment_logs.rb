# Removes secret values already sitting in stored deployment logs.
#
# A live OAuth client secret was found in plaintext in one of them. kamal prints
# the full `docker run` line including inline values for anything the app declared
# under `env: clear:`, and KamalDeployer captured that stdout verbatim. The capture
# is fixed going forward; this deals with the copies that already exist.
#
# Irreversible on purpose. `down` does nothing, because restoring a credential into
# a database is not a rollback anybody wants — and the value is gone from here
# either way once it is rotated.
#
# Rotation is still the only thing that actually closes the exposure. This removes
# a copy; it does not un-disclose anything.
class ScrubSecretsFromDeploymentLogs < ActiveRecord::Migration[8.0]
  def up
    return unless defined?(SecretScrubber)

    scanned = 0
    changed = 0

    Deployment.where.not(log: [ nil, "" ]).find_each(batch_size: 100) do |deployment|
      scanned += 1
      original = deployment.log.to_s
      cleaned = SecretScrubber.new(deployment.app).scrub(original)
      next if cleaned == original

      # update_columns: no callbacks, no broadcasts, no touching updated_at. This is
      # a redaction, not an edit anyone should be notified about.
      deployment.update_columns(log: cleaned)
      changed += 1
    end

    say "scrubbed #{changed} of #{scanned} deployment logs"
  end

  def down
    say "not reversible: a scrubbed credential is not restored, it is rotated"
  end
end
