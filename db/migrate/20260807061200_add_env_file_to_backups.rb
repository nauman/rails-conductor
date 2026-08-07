# Some apps are not containers. A Hatchbox-style app runs as systemd + puma on
# the host with its DATABASE_URL in a per-app env file (`.asdf-vars`), and its
# database lives in the HOST postgres — so there is no container to `docker exec`
# and no DATABASE_URL in the SSH session's environment.
#
# Conductor could not back one up at all: `resolve_database_url` returns nil and
# the last-resort branch runs `pg_dump "$DATABASE_URL"` against an empty
# variable. intellecta.co is exactly this, and its "backup" was instead dumping
# an abandoned, EMPTY Docker container left behind by a half-finished migration —
# so it reported success while protecting nothing.
#
# DatabasePull already has this field for the same reason; Backup did not.
class AddEnvFileToBackups < ActiveRecord::Migration[8.1]
  def change
    add_column :backups, :env_file, :string
  end
end
