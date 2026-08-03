require "shellwords"

class DatabaseBackup
  # A real gzipped pg_dump — even of an empty schema — is well over this; an empty
  # gzip stream (what a failed dump leaves) is ~20 bytes. Below this = not a backup.
  MIN_DUMP_BYTES = 200

  attr_reader :backup, :error, :run

  # `run` is the BackupRun the dispatcher already created. Manual paths pass
  # nothing and get one here, so every attempt lands in history no matter how it
  # was triggered.
  def initialize(backup, run: nil, ssh: nil)
    @backup = backup
    @run = run
    @injected_ssh = ssh
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

    ssh = @injected_ssh || SshConnection.new(server)

    # Create backup filename
    timestamp = Time.current.strftime("%Y%m%d_%H%M%S")
    filename = "#{backup.bucket_name}_#{timestamp}.sql.gz"
    # Escaped everywhere it reaches a shell. bucket_name is now format-validated
    # too, but validation is one migration or one `update_column` away from being
    # bypassed — the six routes closed on 08-01 taught that either layer alone is
    # a single mistake from being reopened.
    local_path = esc("/tmp/#{filename}")

    # Run the pipeline under pipefail. EVERY dump is `pg_dump … | gzip > file`,
    # and without it the exit code is GZIP's, not pg_dump's: a dump that writes
    # 4 MB and then dies on a dropped connection exits 0, clears the 200-byte
    # floor, uploads, and records completed. A truncated backup passing as
    # healthy is worse than one that fails.
    #
    # `bash -o pipefail -c` rather than `set -o pipefail`, because the SSH exec
    # shell is /bin/sh, which on Debian/Ubuntu is dash and has no pipefail.
    dump_cmd = "bash -o pipefail -c #{esc(build_dump_command(ssh, local_path))}"
    dump = ssh.execute_with_status(dump_cmd)
    unless dump[:success]
      return fail_with("Database dump failed: #{(dump[:stderr].presence || dump[:output]).to_s.strip[0, 200]}")
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

    # Size proves bytes were written; it does not prove the archive is complete.
    # `gzip -t` reads the whole stream and rejects a truncated one — the failure
    # mode pipefail alone still misses when the writer dies mid-stream without a
    # non-zero status.
    unless ssh.execute_with_status("gzip -t #{local_path}")[:success]
      return fail_with("Dump is not a valid gzip archive — truncated or corrupt, not recording success")
    end

    # Upload to cloud storage
    unless upload_to_storage(ssh, local_path, filename)
      return fail_with("Upload failed: #{@error}")
    end

    # Cleanup
    ssh.execute("rm -f #{local_path}")

    run.complete!(size_bytes: size_bytes, object_key: filename)
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

  # Credential material is operator-supplied and reaches the shell as env
  # assignments; an unescaped key containing a space or a quote breaks the
  # command apart. Escaped for the same reason as the bucket name.
  def credential_env(vendor, cred)
    [
      "AWS_ACCESS_KEY_ID=#{esc(cred.api_key)}",
      "AWS_SECRET_ACCESS_KEY=#{esc(cred.api_secret)}",
      "AWS_DEFAULT_REGION=#{esc(vendor.region(cred))}"
    ]
  end

  # `ssh.execute` returns the command OUTPUT, not its exit status, so
  # `execute(cmd) ? true : fail` only ever caught an unreachable box. A failed
  # upload returns its error text — a non-empty String, therefore truthy — and
  # every backup in the fleet was recorded as uploaded while the bucket stayed
  # empty. The dump was real, the local copy was then deleted, and the row said
  # "completed" with a size. Check the exit code.
  def upload_to_storage(ssh, local_path, filename)
    return true if backup.provider == "local" # nothing to upload — keep the file

    vendor = BackupVendors[backup.provider]
    return fail_upload("Unsupported provider: #{backup.provider}") unless vendor

    res = ssh.execute_with_status(s3_upload_command(vendor, local_path, filename))
    unless res[:success]
      return fail_upload((res[:stderr].presence || res[:output]).to_s.strip[0, 200])
    end

    confirm_uploaded(ssh, vendor, filename)
  end

  # Exit 0 is the command's opinion. Ask the bucket instead: the object must be
  # listed, with a non-zero size. This is the same discipline the 0-byte dump
  # guard applies one step earlier — an upload that "succeeded" and stored
  # nothing is not a backup.
  def confirm_uploaded(ssh, vendor, filename)
    res = ssh.execute_with_status(s3_head_command(vendor, filename))
    return fail_upload("uploaded object not found in bucket: #{filename}") unless res[:success]

    size = res[:output].to_s.split(/\s+/).find { |t| t.match?(/\A\d+\z/) }.to_i
    return fail_upload("uploaded object #{filename} is #{size} bytes in the bucket") if size < MIN_DUMP_BYTES

    true
  end

  def s3_head_command(vendor, filename)
    cred = backup.credential
    env = credential_env(vendor, cred)
    cmd = [ "aws", "s3", "ls", esc("s3://#{backup.bucket_name}/#{filename}") ]
    cmd += [ "--endpoint-url", esc(vendor.endpoint(cred)) ] if vendor.endpoint(cred).present?
    "#{env.join(' ')} #{cmd.join(' ')}"
  end

  # One uniform `aws s3 cp` for every S3-compatible vendor. The vendor registry
  # supplies the endpoint + region; the credential supplies the keys. A custom
  # endpoint is added only when the vendor needs one (AWS S3 uses the default).
  def s3_upload_command(vendor, local_path, filename)
    cred = backup.credential
    env = credential_env(vendor, cred)
    cmd = [ "aws", "s3", "cp", local_path, esc("s3://#{backup.bucket_name}/#{filename}") ]
    cmd += [ "--endpoint-url", esc(vendor.endpoint(cred)) ] if vendor.endpoint(cred).present?
    "#{env.join(' ')} #{cmd.join(' ')}"
  end

  def fail_upload(message)
    @error = message
    false
  end
end
