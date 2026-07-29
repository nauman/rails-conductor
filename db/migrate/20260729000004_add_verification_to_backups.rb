# A backup nobody has restored is not a backup — it's a file in a bucket and a hope.
# These columns let Conductor say which of the two it has (design B2).
#
#   verification_status  never_tested | verified | failed
#   verified_at          when a restore last PROVED the dump
#   verification_note    what the proof was, or why it failed (row counts, error)
class AddVerificationToBackups < ActiveRecord::Migration[8.1]
  def change
    add_column :backups, :verification_status, :string, null: false, default: "never_tested"
    add_column :backups, :verified_at, :datetime
    add_column :backups, :verification_note, :string
  end
end
