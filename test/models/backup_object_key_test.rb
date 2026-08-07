require "test_helper"

# Every backup in the fleet wrote its dump to `<bucket>_<timestamp>.sql.gz`.
#
# One bucket holds thirteen apps, so every object was named after the BUCKET —
# `pavelabs-backups_20260807_045320.sql.gz` — and nothing in the key said which
# app it came from. Two consequences, the second one destructive:
#
#   1. You cannot tell whose dump you are looking at, which makes a restore a
#      guess. A backup you cannot identify is not a backup.
#   2. The stamp is only second-resolution and every app shares one schedule
#      window ("daily" = the same minute). Two apps finishing their dump in the
#      same second write the SAME key, and S3/R2 PUT is last-write-wins — one
#      app's backup silently overwrites another's.
#
# The key must identify the app.
class BackupObjectKeyTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "key@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
  end

  def backup_for(app: nil)
    @org.backups.create!(provider: "cloudflare_r2", bucket_name: "shared-bucket",
                         server: @server, app: app, schedule: "daily", enabled: true)
  end

  test "the key is namespaced by the app, not the bucket" do
    app = @org.apps.create!(name: "Calm.page", slug: "calm-page", server: @server)

    key = backup_for(app: app).object_key_for(Time.utc(2026, 8, 7, 4, 53, 20))

    assert_equal "calm-page/calm-page_20260807_045320.sql.gz", key
  end

  # The bug, stated as a test: two apps backing up in the same second.
  test "two apps in one bucket cannot collide" do
    a = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server)
    b = @org.apps.create!(name: "Starrrs", slug: "starrrs", server: @server)
    at = Time.utc(2026, 8, 7, 3, 0, 0)

    refute_equal backup_for(app: a).object_key_for(at), backup_for(app: b).object_key_for(at)
  end

  # A backup can be attached to a server with no app (a whole-box database).
  # It still must not land under a name shared with everything else.
  test "a backup with no app is namespaced by its server" do
    key = backup_for(app: nil).object_key_for(Time.utc(2026, 8, 7, 4, 53, 20))

    assert_match %r{\Aserver-#{@server.id}/server-#{@server.id}_20260807_045320\.sql\.gz\z}, key
  end

  # The key reaches a shell (`aws s3 cp`, `aws s3 ls`) and a local /tmp path.
  # App slugs are validated, but this is the layer that would carry a bad one
  # into a command, so it refuses rather than trusts.
  test "the prefix contains nothing that could reach a shell" do
    app = @org.apps.create!(name: "Odd", slug: "odd-app", server: @server)

    assert_match %r{\A[a-z0-9][a-z0-9\-]*\z}, backup_for(app: app).object_prefix
  end
end
