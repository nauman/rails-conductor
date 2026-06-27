# Restores a chosen backup object from object storage (R2 / S3) into a target
# PostgreSQL database, running over SSH on the backup's server. The symmetric
# inverse of DatabaseBackup (which does `pg_dump | gzip` → upload): pull the
# `.sql.gz` object down, then `gunzip -c … | psql <target>`.
#
# Slice 1 of roadmap slot 21 (docs/plans/postgres-restore.md;
# docs/roadmap/21-backup-restore.html). The target is given
# explicitly (a fresh / scratch database) — restoring over an existing database
# is gated separately (slice 4). Streams progress to #log.
class DatabaseRestore
  attr_reader :backup, :error, :log

  def initialize(backup, object_key:, target_url:, ssh_override: nil)
    @backup = backup
    @object_key = object_key
    @target_url = target_url
    @ssh_override = ssh_override
    @log = +""
  end

  def run!
    return fail_with("No object_key given") if @object_key.blank?
    return fail_with("No target_url given") if @target_url.blank?
    return fail_with("No credential configured") unless backup.credential

    server = backup.server || backup.app&.server
    return fail_with("No server with SSH access") unless server&.ssh_configured?

    ssh = @ssh_override || SshConnection.new(server)
    remote_path = "/tmp/conductor-restore-#{backup.id}-#{timestamp}.sql.gz"

    append_log("=== Restoring #{@object_key} into target database ===")

    append_log("[1/2] Downloading #{@object_key} from #{backup.provider}...")
    unless step_ok?(ssh.execute_with_status(download_command(remote_path)))
      return fail_with("Backup download failed")
    end

    append_log("[2/2] Restoring with psql...")
    unless step_ok?(ssh.execute_with_status(restore_command(remote_path)))
      return fail_with("Database restore failed")
    end

    ssh.execute("rm -f #{remote_path}")
    append_log("=== Done ===")
    true
  rescue StandardError => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  # `aws s3 cp s3://bucket/key <remote_path>` with the provider's credentials.
  # Mirrors DatabaseBackup#upload_to_r2 so a restore reads exactly what a backup
  # wrote (same endpoint convention).
  def download_command(remote_path)
    cred = backup.credential
    src = "s3://#{backup.bucket_name}/#{@object_key}"
    base = %(AWS_ACCESS_KEY_ID=#{cred.api_key} AWS_SECRET_ACCESS_KEY=#{cred.api_secret} ) +
           %(aws s3 cp #{src} #{remote_path})
    endpoint.present? ? "#{base} --endpoint-url #{endpoint}" : base
  end

  # Backups are plain SQL gzipped (`pg_dump | gzip`), so restore = gunzip | psql.
  def restore_command(remote_path)
    %(gunzip -c #{remote_path} | psql #{shellesc(@target_url)})
  end

  # R2 needs the account endpoint; native S3 uses the default. Mirrors
  # DatabaseBackup's convention (account id carried on the credential).
  def endpoint
    case backup.provider
    when "cloudflare_r2" then "https://#{backup.credential.api_secret}.r2.cloudflarestorage.com"
    else ""
    end
  end

  def step_ok?(result) = result[:success]

  def timestamp = Time.current.strftime("%Y%m%d%H%M%S")

  def shellesc(str) = "'#{str.to_s.gsub("'", "'\\\\''")}'"

  def append_log(line)
    @log << "#{line}\n"
    Rails.logger.info "[BackupRestore:#{backup.id}] #{line}"
  end

  def fail_with(message)
    @error = message
    append_log("FAILED: #{message}")
    false
  end
end
