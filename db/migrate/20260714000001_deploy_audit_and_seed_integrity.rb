class DeployAuditAndSeedIntegrity < ActiveRecord::Migration[8.1]
  def change
    # Durable audit trail for the preflight gate:
    # - a blocked attempt (esp. an auto-deploy webhook) becomes a persisted
    #   Deployment with status "blocked" + the preflight snapshot, instead of being
    #   silently dropped after an HTTP 200.
    # - a forced deploy records that it overrode the gate, and which blockers.
    add_column :deployments, :forced, :boolean, default: false, null: false
    add_column :deployments, :preflight_snapshot, :text

    # Seed integrity: a bare ledger row must not default to a green "succeeded".
    # Unproven rows default to "pending"; only an explicit succeeded run with
    # evidence (applied_at) makes the preflight seeds gate green.
    change_column_default :seed_applications, :status, from: "succeeded", to: "pending"
  end
end
