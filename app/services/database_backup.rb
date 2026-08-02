require "shellwords"

class DatabaseBackup
  # A real gzipped pg_dump — even of an empty schema — is well over this; an empty
  # gzip stream (what a failed dump leaves) is ~20 bytes. Below this = not a backup.
  MIN_DUMP_BYTES = 200

  attr_reader :backup, :error, :run

  # `run` is the BackupRun the dispatcher already created. Manual paths pass
  # nothing and get one here, so every attempt lands in history no matter how it
  # was triggered.
  def initialize(backup, run: nil)
    @backup = backup
    @run = run
  end

  def run!
    @run ||= backup.record_dispatch!(trigger: "manual")
    @run.start!
    # Stamps last_run_at as well — see Backup#begin_run!.
    backup.begin_run!

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

    dump_cmd = build_dump_command(ssh, local_path)
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

    run.complete!(size_bytes: size_bytes)
    backup.mark_completed!(size_bytes: size_bytes)

    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  def fail_with(message)
    @error = message
    run&.fail!(message)
    backup.update!(status: "failed", last_run_at: Time.current)
    backup.calculate_next_run if backup.enabled?
    Rails.logger.error "[Backup:#{backup.id}] #{message}"

    # Send notification
    AlertMailer.backup_failed(backup).deliver_later

    false
  end

  # ActiveRecord reports the app's real DSN however it's wired (DATABASE_URL,
  # database.yml, or credentials) — so an app can tell us its own connection even
  # when it exposes no DATABASE_URL env. Prints CONDUCTOR_DSN=<url> for us to parse.
  RAILS_DSN_PROBE =
    "bin/rails runner \"require %q(cgi); c=ActiveRecord::Base.connection_db_config.configuration_hash; " \
    "puts %q(CONDUCTOR_DSN=postgres://)+CGI.escape(c[:username].to_s)+%q(:)+CGI.escape(c[:password].to_s)+" \
    "%q(@)+c[:host].to_s+%q(:)+(c[:port]||5432).to_s+%q(/)+c[:database].to_s\"".freeze

  # The app's live DATABASE_URL, resolved most-authoritative first:
  #   1. Conductor's derived URL (dedicated DBs it manages), then
  #   2. the container's DATABASE_URL env (Conductor-managed apps set it), then
  #   3. ASK THE APP — older/unregistered apps (e.g. Kuickr) carry no derived URL
  #      and no DATABASE_URL env; they configure the DB via database.yml, but
  #      ActiveRecord still resolves the real connection, so the app reports it.
  def resolve_database_url(ssh)
    app = backup.app
    derived = app&.derived_database_url(server: backup.server || app&.server)
    return derived if derived.present?

    container = dump_source_container(app)
    return nil unless container

    ssh.execute("docker exec #{container} printenv DATABASE_URL")
    env_url = ssh.output.to_s.strip
    return env_url if env_url.start_with?("postgres")

    ssh.execute("docker exec #{container} #{RAILS_DSN_PROBE}")
    ssh.output.to_s[/CONDUCTOR_DSN=(\S+)/, 1]
  end

  # Build the dump command, most-reliable source first:
  #   1. DEDICATED DB CONTAINER (<slug>-db) — the best source: it has the exact
  #      server-version pg_dump (no client-too-old refusal, incl. pg18), local
  #      access, and runs even when the APP is stopped. pg_dumpall captures every
  #      database + roles. Superuser is POSTGRES_USER, or `postgres` when the image
  #      left it unset (e.g. the pgvector image).
  #   2. SHARED-cluster apps (no dedicated container) — resolve the app's DSN and
  #      run a version-matched pg_dump on the app's docker network.
  # A failed dump can still leave an empty gzip, so run! rejects anything under
  # MIN_DUMP_BYTES.
  def build_dump_command(ssh, output_path)
    app = backup.app

    if (db = dedicated_db_container(ssh, app))
      return %(docker exec #{esc(db)} sh -c 'pg_dumpall -U "${POSTGRES_USER:-postgres}"' | gzip > #{output_path})
    end

    url = resolve_database_url(ssh)
    net = app&.deploy_network
    if url.present? && net.present?
      "docker run --rm --network #{esc(net)} #{esc(PostgresContainerClient::DEFAULT_IMAGE)} pg_dump #{esc(url)} | gzip > #{output_path}"
    elsif url.present?
      "pg_dump #{esc(url)} | gzip > #{output_path}"
    else
      # Last resort (native/host app): DATABASE_URL from the host env.
      %(pg_dump "$DATABASE_URL" | gzip > #{output_path})
    end
  end

  # The app's dedicated DB container name if one is actually running on the box,
  # else nil. Named <slug>-db by DedicatedDbProvisioner.
  def dedicated_db_container(ssh, app)
    return nil unless app
    name = "#{app.slug}-db"
    ssh.execute("docker ps -q -f name=^#{esc(name)}$")
    ssh.output.to_s.strip.present? ? name : nil
  end

  # A shell expression resolving to the app's running container id, or nil for a
  # native app. Kamal containers are per-release (found by label); non-kamal
  # docker apps have the fixed name conductor-<slug>.
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
