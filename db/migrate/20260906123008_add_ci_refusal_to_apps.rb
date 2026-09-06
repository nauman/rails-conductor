class AddCiRefusalToApps < ActiveRecord::Migration[8.0]
  def change
    # A CI venue that cannot take the work is not an error — the build falls back and
    # the deploy succeeds. But a PERMANENT refusal (an invalid workflow file, say)
    # then repeats forever behind a green deploy, visible only as one line in a log
    # nobody re-reads. Recording it turns a silent fallback into something a report
    # can surface. Cleared on the first successful CI build.
    add_column :apps, :ci_refused_reason, :string
    add_column :apps, :ci_refused_at, :datetime
    add_column :apps, :ci_refused_detail, :text
  end
end
