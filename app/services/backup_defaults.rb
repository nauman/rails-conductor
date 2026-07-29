# Turning a backup on should ask nothing (design B1).
#
# The fleet had 0 of 12 apps protected — not carelessness, arithmetic: enabling one asked
# for a provider, a bucket, a credential and a schedule, per app. Conductor already knows
# every one of those except your preference, and it should assume a sane one rather than
# leave databases unprotected while it waits to be told.
#
# Every value here is a DEFAULT the operator changes afterwards. The one thing this never
# does is guess a destination it can't reach: without a connected, verified storage
# credential it returns nil, because a backup pointed at an invented bucket is worse than
# no backup — it reports success and protects nothing.
class BackupDefaults
  SCHEDULE = "daily".freeze          # nightly; the hour comes from the scheduler
  RETENTION_DAYS = 14
  # R2 first because that's what this fleet has connected; the list is the order we'd
  # rather use, not a preference the operator can't override.
  PROVIDER_BY_CREDENTIAL = { "cloudflare" => "cloudflare_r2", "aws" => "aws_s3" }.freeze

  def initialize(app)
    @app = app
  end

  # An unsaved Backup with everything filled in, or nil when we'd have to invent something.
  def build
    return nil unless protectable?

    credential = storage_credential
    return nil unless credential

    @app.backups.new(
      organization: @app.organization,
      server: @app.server,
      credential: credential,
      provider: PROVIDER_BY_CREDENTIAL.fetch(credential.provider, "cloudflare_r2"),
      bucket_name: bucket_name,
      schedule: SCHEDULE,
      retention_days: RETENTION_DAYS,
      enabled: true
    )
  end

  def protect!
    backup = build
    return nil unless backup

    backup.save!
    backup
  end

  private

  # Never auto-protect an app the operator has parked — a placeholder or one awaiting
  # migration into a calm.page theme. Acting on those is the same failure as nagging
  # about them.
  def protectable? = @app.naggable? && @app.organization.present?

  # Only a connected AND verified credential counts. An unverified one may name an
  # account its token can no longer reach, which is exactly the kind of backup that
  # looks fine until you need it.
  def storage_credential
    @app.organization.credentials
        .where(provider: PROVIDER_BY_CREDENTIAL.keys, active: true)
        .where.not(verified_at: nil)
        .order(:provider)
        .first
  end

  # One bucket, one prefix per app (design B6 — changeable). Prefixed rather than a
  # bucket each so a new app needs no bucket creation and no new permission.
  def bucket_name
    ENV["CONDUCTOR_BACKUP_BUCKET"].presence || "#{@app.organization.name.parameterize}-backups"
  end
end
