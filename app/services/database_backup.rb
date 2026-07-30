require "shellwords"

class DatabaseBackup
  # A real gzipped pg_dump — even of an empty schema — is well over this; an empty
  # gzip stream (what a failed dump leaves) is ~20 bytes. Below this = not a backup.
  MIN_DUMP_BYTES = 200

  attr_reader :backup, :error

  def initialize(backup)
    @backup = backup
  end

  def run!
    backup.update!(status: "running")

    unless backup.credential
      return fail_with("No credential configured")
    end

    server = backup.server || backup.app&.server
    unless server&.ssh_configured?
      return fail_with("No server with SSH access")
    end

    ssh = SshConnection.new(server)

    # Create backup filename
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    filename = "#{backup.bucket_name}_#{timestamp}.sql.gz"
    local_path = "/tmp/#{filename}"

    # Dump the database (assumes PostgreSQL - extend for MySQL)
    dump_cmd = build_dump_command(local_path)
    unless ssh.execute(dump_cmd)
      return fail_with("Database dump failed: #{ssh.error}")
    end

    # Get file size
    ssh.execute("stat -f%z #{local_path} 2>/dev/null || stat -c%s #{local_path}")
    size_bytes = ssh.output.to_s.strip.to_i

    # Refuse to record an empty/near-empty dump as a success. A failed pg_dump can
    # still leave a ~20-byte gzip (an empty stream), and a real dump — even of an
    # empty schema — is far larger. Recording that as "completed" is the exact
    # "reports success, protects nothing" trap, so fail loud instead.
    if size_bytes < MIN_DUMP_BYTES
      return fail_with("Dump produced only #{size_bytes} bytes — treating as a failed/empty backup, not recording success")
    end

    # Upload to cloud storage
    unless upload_to_storage(ssh, local_path, filename)
      return fail_with("Upload failed: #{@error}")
    end

    # Cleanup
    ssh.execute("rm -f #{local_path}")

    # Mark completed
    backup.update!(
      status: "completed",
      size_bytes: size_bytes,
      completed_at: Time.current
    )

    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  def fail_with(message)
    @error = message
    backup.update!(status: "failed", last_run_at: Time.current)
    backup.calculate_next_run if backup.enabled?
    Rails.logger.error "[Backup:#{backup.id}] #{message}"

    # Send notification
    AlertMailer.backup_failed(backup).deliver_later

    false
  end

  # Build the dump command. Three hard-won requirements the old host `pg_dump
  # $DATABASE_URL` missed (it silently produced an empty 20-byte gzip):
  #   1. THE REAL URL — Conductor's DB records are incomplete (shared / unregistered
  #      apps have no derived URL), but the app's OWN container always carries the
  #      live DATABASE_URL. Read it from there, so dedicated AND shared apps work.
  #   2. VERSION MATCH — pg_dump refuses a server newer than the client. The app
  #      containers ship pg_dump 15 while the DBs are 16, so dumping IN them wrote
  #      nothing. Run pg_dump from a matching Postgres image instead.
  #   3. RESOLVABLE HOST — the DB URL host is a container name resolvable only on
  #      the app's docker network, so run that matching client THERE.
  # A failed dump can still leave an empty gzip (the pipe exits with gzip's
  # success), so run! also rejects any dump under MIN_DUMP_BYTES.
  def build_dump_command(output_path)
    app = backup.app
    container = dump_source_container(app)
    net = app&.deploy_network

    if container && net.present?
      client = "docker run --rm --network #{esc(net)} #{esc(PostgresContainerClient::DEFAULT_IMAGE)} pg_dump"
      %(u="$(docker exec #{container} printenv DATABASE_URL)"; #{client} "$u" | gzip > #{output_path})
    else
      # Native/host apps: no container; DATABASE_URL lives in the host/systemd env.
      %(pg_dump "$DATABASE_URL" | gzip > #{output_path})
    end
  end

  # A shell expression that resolves to the app's running container id, or nil for
  # a native (host-process) app. Kamal containers are per-release (found by label);
  # non-kamal docker apps have the fixed name conductor-<slug>.
  def dump_source_container(app)
    return nil unless app
    if app.kamal?
      svc = esc(app.kamal_service_candidates.first.to_s)
      "$(docker ps -q --filter label=service=#{svc} --filter label=role=web | head -1)"
    elsif app.deploy_method == "docker"
      esc(app.container_name)
    end
  end

  def esc(value) = Shellwords.escape(value.to_s)

  def upload_to_storage(ssh, local_path, filename)
    return true if backup.provider == "local" # nothing to upload — keep the file

    vendor = BackupVendors[backup.provider]
    return fail_upload("Unsupported provider: #{backup.provider}") unless vendor

    ssh.execute(s3_upload_command(vendor, local_path, filename)) ? true : fail_upload(ssh.error)
  end

  # One uniform `aws s3 cp` for every S3-compatible vendor. The vendor registry
  # supplies the endpoint + region; the credential supplies the keys. A custom
  # endpoint is added only when the vendor needs one (AWS S3 uses the default).
  def s3_upload_command(vendor, local_path, filename)
    cred = backup.credential
    env = [
      "AWS_ACCESS_KEY_ID=#{cred.api_key}",
      "AWS_SECRET_ACCESS_KEY=#{cred.api_secret}",
      "AWS_DEFAULT_REGION=#{vendor.region(cred)}"
    ]
    cmd = [ "aws", "s3", "cp", local_path, "s3://#{backup.bucket_name}/#{filename}" ]
    cmd += [ "--endpoint-url", vendor.endpoint(cred) ] if vendor.endpoint(cred).present?
    "#{env.join(' ')} #{cmd.join(' ')}"
  end

  def fail_upload(message)
    @error = message
    false
  end
end
