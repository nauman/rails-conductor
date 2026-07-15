class RestoreWronglyDowngradedDeployTokens < ActiveRecord::Migration[8.1]
  # SUPERSEDED — intentionally a no-op. The original version promoted every
  # org-less "read" token held by an operator to "deploy" to recover tokens the
  # 20260715000002 bug downgraded. But that query can't tell a bug victim from a
  # token deliberately issued read-only (monitoring, low-trust integrations), so
  # it silently granted write to those bearers. Promoting an existing bearer
  # token is never a safe recovery.
  #
  # Migration 20260715000005 instead fails CLOSED (any ambiguous org-less
  # operator write token -> read); owners who need deploy re-mint an org-bound
  # deploy token. This class stays as a no-op so already-migrated databases keep
  # a consistent schema_migrations history.
  def up
  end

  def down
  end
end
