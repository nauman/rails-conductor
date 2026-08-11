# Copied from `rails g jazari:upgrade` (jazari 0.3.0).
#
# Provenance on the runbook: WHY the row exists, not just that it does. Without
# it the backfill in 20260811090001 makes every app read as diverged on day one,
# because `custom?` only answers "does a row exist" — and comparing content
# against the canon cannot separate them either, since a backfilled runbook
# genuinely differs.
#
# Additive and nullable in one deploy, safe ahead of the code that writes it:
# NULL is truthful for every existing row, meaning "this predates provenance".
class AddJazariRunbookOrigin < ActiveRecord::Migration[8.0]
  def change
    add_column :jazari_runbooks, :origin, :string
  end
end
