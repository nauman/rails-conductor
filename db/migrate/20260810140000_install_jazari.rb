# frozen_string_literal: true

# R3 PHASE 1: install jazari alongside the existing deploy runbooks.
#
# Purely additive. Nothing existing is touched — `apps.deploy_runbook` and
# `deploy_checklist_items` keep working exactly as they do today, and every
# current caller (the MCP tool, the REST controller, the view partial, the
# fleet-status tool, App#runbook_summary) is untouched.
#
# What this UNLOCKS is the thing this app most lacks: rituals that belong to no
# single record — verify a backup, triage an alert, provision a server — which
# today live in session logs, learnings files, and agents' private memory, and
# so cannot be called by name.
#
# Migrating the per-app deploy runbooks onto these tables is PHASE 2 and is
# deliberately not here: production carries live checklists whose INTEGER ids
# are quoted in deploy documentation and held in running agents' context. That
# migration needs a persisted legacy-id map and a row-count equality check, and
# it must not ride along with a feature addition.
class InstallJazari < ActiveRecord::Migration[8.1]
  def change
    create_table :jazari_recipes do |t|
      t.string  :recipe_id, null: false
      t.integer :version, null: false, default: 1
      t.string  :topic, null: false
      t.text    :description, null: false, default: ""
      t.jsonb   :checklist, null: false, default: []
      t.string  :run_policy, null: false, default: "unrestricted"
      t.timestamps
      t.index :recipe_id, unique: true
      t.check_constraint "run_policy IN ('unrestricted', 'once_per_calendar_day')",
        name: "jazari_recipes_run_policy_chk"
    end

    create_table :jazari_anchors do |t|
      t.string :scope_type, null: false
      t.bigint :scope_id, null: false
      t.string :key, null: false
      t.timestamps
      t.index %i[scope_type scope_id key], unique: true
    end

    create_table :jazari_runbooks do |t|
      t.string  :runbookable_type, null: false
      t.bigint  :runbookable_id, null: false
      t.string  :recipe_id, null: false
      t.string  :topic, null: false
      t.text    :description, null: false, default: ""
      t.jsonb   :checklist, null: false, default: []
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[runbookable_type runbookable_id], unique: true
      t.index :recipe_id
    end

    create_table :jazari_runs do |t|
      t.string      :recipe_id, null: false
      t.string      :source_digest, null: false
      t.string      :subject_type
      t.bigint      :subject_id
      t.string      :actor_ref, null: false
      t.timestamptz :started_at, null: false
      t.date        :started_on, null: false
      t.string      :idempotency_policy, null: false, default: "unrestricted"
      t.timestamptz :finished_at
      t.string      :outcome
      t.jsonb       :checklist_snapshot, null: false
      t.jsonb       :ticks, null: false, default: []
      t.jsonb       :evidence, null: false, default: []
      t.integer     :lock_version, null: false, default: 0
      t.timestamps
      t.index %i[recipe_id started_at]
      t.index %i[subject_type subject_id started_at]
      t.check_constraint "idempotency_policy IN ('unrestricted', 'once_per_calendar_day')",
        name: "jazari_runs_idempotency_policy_chk"
      t.check_constraint "started_on = (started_at AT TIME ZONE 'UTC')::date",
        name: "jazari_runs_started_on_utc_chk"
      t.check_constraint "(subject_type IS NULL AND subject_id IS NULL) OR " \
                         "(subject_type IS NOT NULL AND subject_id IS NOT NULL)",
        name: "jazari_runs_subject_pair_chk"
    end

    reversible do |dir|
      dir.up do
        # COALESCE is what constrains a subject-less (queue) run at all —
        # without it NULL != NULL and every queue run is unconstrained.
        execute <<~SQL
          CREATE UNIQUE INDEX jazari_runs_once_per_day_idx
          ON jazari_runs (
            recipe_id,
            COALESCE(subject_type, ''),
            COALESCE(subject_id, 0),
            started_on
          )
          WHERE idempotency_policy = 'once_per_calendar_day';
        SQL
      end
    end
  end
end
