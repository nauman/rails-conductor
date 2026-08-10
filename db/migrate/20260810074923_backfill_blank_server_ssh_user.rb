# Server#ssh_user_or_default used to fall back to "root" when ssh_user was blank,
# so any row registered without an explicit user silently connected as root. That
# fallback is now "deploy" (root is provisioning-only and must be asked for
# explicitly), but a codex review caught the migration gap: an EXISTING row with a
# NULL ssh_user was relying on the old root fallback, and every implicit
# SshConnection for it — deploys, backups, health checks, package ops — would start
# authenticating as a user that may not exist on that box.
#
# Make the previously-implicit identity explicit instead of guessing which rows
# meant root. This preserves behaviour for rows that already exist, so the changed
# default only affects servers registered from now on.
class BackfillBlankServerSshUser < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL.squish
      UPDATE servers SET ssh_user = 'root'
      WHERE ssh_user IS NULL OR trim(ssh_user) = ''
    SQL
  end

  def down
    # Irreversible by intent: a backfilled 'root' is indistinguishable from one an
    # operator chose, and leaving the identity explicit is the safe direction.
  end
end
