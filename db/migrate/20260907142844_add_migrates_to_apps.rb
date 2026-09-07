class AddMigratesToApps < ActiveRecord::Migration[8.0]
  def up
    # Does this app run database migrations? DECLARED, not probed.
    #
    # Probing the image for `bin/rails` looked cheaper and was wrong twice: `test -f`
    # returns 1 for a denied path traversal as well as a missing file, and running the
    # probe needs `--entrypoint sh`, which bypasses any `cd` the real entrypoint
    # performs — so an image that runs Rails fine can be read as "does not migrate"
    # and have its gate silently skipped. A guess that fails open on a safety check is
    # worse than no check, because it looks like one.
    add_column :apps, :migrates, :boolean, default: true, null: false

    # NO GRANDFATHER CLAUSE, and this was reversed twice before it was right.
    #
    # The first attempt switched every non-kamal app OFF, because the gate had never
    # run for them and turning it on at once could break a deploy nobody is watching.
    # The second tried to switch off only apps with no database Conductor knows of —
    # and that missed Conductor itself and one other Rails app, whose DATABASE_URL
    # does not live in `env_variables`. A heuristic that misses the very apps it
    # exists to protect is not a heuristic, it is a silent opt-out.
    #
    # What makes ON safe for everyone is the ordering fix that shipped with this
    # column: the gate runs in a throwaway container BEFORE anything is stopped. So
    # for a non-Rails app the worst case is a deploy that fails and changes nothing —
    # the running release never moves — and the error names the one checkbox to
    # clear. For a Rails app the worst case of the other default is a release live
    # against an unmigrated schema, which is 500s in production and silent until a
    # user finds it.
    #
    # A loud no-op beats a quiet outage, so everything gets the gate and the
    # exceptions are declared by hand.
  end

  def down
    remove_column :apps, :migrates
  end
end
