class RunBackupTool
  include ActorScoped

  DEFINITION = {
    name: "run_backup",
    description: "Run an app's database backup NOW (synchronously) and report the real result — dumps the DB and uploads to the configured store. app_id/app_name. Proves the backup actually produces an artifact instead of trusting the schedule (guards the 'reports success, protects nothing' trap). If the app has no backup yet but has a verified storage credential, one is created with safe defaults first.",
    input_schema: {
      type: "object",
      properties: {
        app_id:   { type: "integer", description: "target app by id (or app_name)" },
        app_name: { type: "string",  description: "target app by name (or app_id)" }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    backup = app.backups.enabled.first || app.backups.first || BackupDefaults.new(app).protect!
    return Result.fail("No backup configured for #{app.name} and no connected+verified storage credential to auto-create one.") unless backup

    service = DatabaseBackup.new(backup)
    ok = service.run!
    backup.reload

    Result.ok({
      app: app.name,
      ok: ok,
      status: backup.status,
      size_bytes: backup.size_bytes,
      completed_at: backup.completed_at&.iso8601,
      provider: backup.provider,
      bucket: backup.bucket_name,
      error: ok ? nil : service.error,
      message: if ok
                 "Backup succeeded for #{app.name}: #{backup.size_bytes} bytes → #{backup.provider}/#{backup.bucket_name}. This is what the nightly schedule will now produce."
               else
                 "Backup FAILED for #{app.name}: #{service.error}. The nightly schedule would fail the same way — fix before relying on it."
               end,
      _organization: app.organization
    })
  rescue StandardError => e
    Result.fail("Backup run errored: #{e.message}")
  end
end
