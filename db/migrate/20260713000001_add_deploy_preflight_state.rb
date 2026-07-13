class AddDeployPreflightState < ActiveRecord::Migration[8.1]
  def change
    # Threads gate: an explicit, Conductor-native "do not deploy" flag an agent or
    # operator sets while a coordination thread is owed (docs/threads/*). Conductor
    # can't parse every app repo's markdown, but it can hold a deploy on this flag.
    add_column :apps, :deploy_hold, :boolean, default: false, null: false
    add_column :apps, :deploy_hold_reason, :string

    # Audit gate: the last ServerAudit rollup, persisted so a deploy preflight can
    # read it without a live SSH round-trip (and flag stale/at_risk before shipping).
    add_column :servers, :last_audit_status, :string
    add_column :servers, :last_audit_at, :datetime

    # Seed lifecycle ledger: one row per recorded seed run for an app, so "were the
    # seeds applied?" becomes a query instead of a guess (the missing half of the
    # migration/seed lifecycle — migrations are already gated post-deploy).
    create_table :seed_applications do |t|
      t.references :app, null: false, foreign_key: true
      t.string :digest                       # digest of db/seeds.rb at apply time
      t.string :status, default: "succeeded", null: false
      t.datetime :applied_at
      t.text :output
      t.timestamps
    end
  end
end
