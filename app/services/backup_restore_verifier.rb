require "shellwords"

# Proves a backup can actually be restored.
#
# Every backup in the fleet read `never_tested` — ten green schedules and zero
# evidence any of them could be brought back. The 0-byte guard catches an empty
# dump; nothing caught a dump that uploads cleanly and will not restore. "We
# take backups" is a claim; "we restored last night's dump into a clean postgres
# and it came back with 187 tables" is a guarantee.
#
# **It never touches a live database.** The dump is restored into a THROWAWAY
# postgres container that this class creates and destroys. That is not merely
# safer than restoring into the real cluster — it is a stronger test, because it
# proves the dump can rebuild from nothing rather than layering onto a schema
# that already exists.
#
# It matters especially here because a dedicated-DB backup is `pg_dumpall`,
# which carries CREATE DATABASE statements: piping that into the live cluster
# could overwrite production. An isolated container makes that impossible rather
# than merely discouraged.
#
# Fails closed. Anything it cannot prove is `failed`, never `verified`.
class BackupRestoreVerifier
  # The restored cluster must contain at least this many tables to count. A
  # restore that "succeeds" into an empty database is the same trap as a 0-byte
  # dump reporting success.
  MIN_TABLES = 1

  # Readiness polling for the throwaway container.
  READY_ATTEMPTS = 30

  Result = Struct.new(:status, :tables, :rows, :detail, keyword_init: true)

  def initialize(backup, ssh: nil)
    @backup = backup
    @server = backup.server || backup.app&.server
    @ssh = ssh || (@server && SshConnection.new(@server))
  end

  def verify!
    run = @backup.runs.verifiable.recent.first
    return skip("no completed backup with a recorded object key to verify") if run.nil?
    return fail!("no server with SSH access") if @ssh.nil?
    return fail!("no credential configured") if @backup.credential.nil?

    @run = run
    # Unique per invocation, not just per run. Two verifiers picking the same
    # latest run would otherwise collide on the name, and the second one's
    # teardown would kill the first one's container mid-restore.
    @token = "conductor-verify-#{run.id}-#{SecureRandom.hex(4)}"

    perform_verification
  rescue StandardError => e
    fail!("verification error: #{e.message}")
  ensure
    teardown
  end

  private

  attr_reader :backup, :run, :token

  def perform_verification
    return fail!("download failed: #{@last_error}") unless download_dump
    return fail!("downloaded archive is truncated or corrupt: #{@last_error}") unless archive_intact?
    return fail!("could not start a throwaway postgres: #{@last_error}") unless start_scratch_postgres
    return fail!("restore failed: #{@last_error}") unless restore_dump

    tables = count_tables
    return fail!("restore produced no tables — the dump is not a usable backup") if tables < MIN_TABLES

    rows = count_rows
    pass(tables, rows)
  end

  # --- steps ---------------------------------------------------------------

  def download_dump
    vendor = BackupVendors[backup.provider]
    return false if vendor.nil?

    cred = backup.credential
    env = [
      "AWS_ACCESS_KEY_ID=#{esc(cred.api_key)}",
      "AWS_SECRET_ACCESS_KEY=#{esc(cred.api_secret)}",
      "AWS_DEFAULT_REGION=#{esc(vendor.region(cred))}"
    ].join(" ")
    cmd = [ "aws", "s3", "cp", esc("s3://#{backup.bucket_name}/#{run.object_key}"), esc(dump_path) ]
    cmd += [ "--endpoint-url", esc(vendor.endpoint(cred)) ] if vendor.endpoint(cred).present?

    ok?("#{env} #{cmd.join(' ')}")
  end

  # A postgres at least as new as the one that produced the dump. Restoring a
  # pg18 dump with a pg16 server fails, so the source container's own image is
  # the safest choice when the app has a dedicated DB.
  def start_scratch_postgres
    started = ok?(
      "docker run -d --name #{esc(token)} -e POSTGRES_PASSWORD=verify " \
      "#{esc(scratch_image)} >/dev/null"
    )
    # Only a container we actually started may be torn down. `docker rm -f` on a
    # name we never created would delete someone else's container that happened
    # to match.
    @container_started = started
    return false unless started

    ok?(
      "for i in $(seq 1 #{READY_ATTEMPTS}); do " \
      "docker exec #{esc(token)} pg_isready -U postgres >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1"
    )
  end

  def scratch_image
    slug = backup.app&.slug
    if slug.present?
      out = capture("docker inspect --format '{{.Config.Image}}' #{esc("#{slug}-db")} 2>/dev/null")
      return out.strip if out.to_s.strip.present?
    end
    PostgresContainerClient::DEFAULT_IMAGE
  end

  # ON_ERROR_STOP stays OFF: a pg_dumpall carries role grants a fresh container
  # may reject, and those are not what is being tested — psql returns 0 through
  # such soft errors, which is what we want.
  #
  # But the pipeline runs under pipefail and its status is NOT discarded. The
  # previous `|| true` threw away the one signal that matters: gunzip failing on
  # a TRUNCATED archive. That let a half-downloaded dump restore a schema with
  # no data and still be recorded `verified` — the exact false guarantee this
  # class exists to prevent.
  def restore_dump
    ok?(
      "bash -o pipefail -c " +
      esc("gunzip -c #{dump_path} | docker exec -i #{esc(token)} psql -U postgres -q >/dev/null 2>&1")
    )
  end

  # Read the archive end-to-end before restoring: a truncated gzip is not a
  # backup, and finding out from a table count afterwards is guesswork.
  def archive_intact?
    ok?("gzip -t #{esc(dump_path)}")
  end

  # Memoised: it is asked once for the table count and once for the rows, and a
  # second SSH round-trip to re-answer the same question is pure cost.
  def restored_database
    return @restored_database if defined?(@restored_database)

    sql = "select datname from pg_database " \
          "where datname not in ('postgres','template0','template1') limit 1"
    out = capture("docker exec #{esc(token)} psql -U postgres -tAc #{esc(sql)}")
    @restored_database = out.to_s.strip.presence || "postgres"
  end

  def count_tables
    sql = "select count(*) from information_schema.tables where table_schema='public'"
    capture("docker exec #{esc(token)} psql -U postgres -d #{esc(restored_database)} -tAc #{esc(sql)}")
      .to_s.strip.to_i
  end

  # Best-effort: a table count proves schema, a row count proves data. Nil
  # rather than zero when it cannot be measured, so "unknown" never reads as
  # "empty".
  def count_rows
    sql = "select coalesce(sum(n_live_tup),0) from pg_stat_user_tables"
    out = capture("docker exec #{esc(token)} psql -U postgres -d #{esc(restored_database)} -tAc #{esc(sql)}")
          .to_s.strip
    out.match?(/\A\d+\z/) ? out.to_i : nil
  end

  def teardown
    return if token.nil? || @ssh.nil?

    # Remove the container ONLY if this invocation started it. Removing by name
    # unconditionally would destroy a container we never created — the name is
    # predictable, and "it matched" is not the same as "it is ours".
    @ssh.execute_with_status("docker rm -f #{esc(token)} >/dev/null 2>&1 || true") if @container_started

    # The dump is ours by construction (the path carries the unique token), so
    # it is always safe to remove — and a failed verification must not leave a
    # multi-hundred-megabyte file behind.
    @ssh.execute_with_status("rm -f #{esc(dump_path)}")
  end

  # --- outcomes ------------------------------------------------------------

  def pass(tables, rows)
    note = "restored #{run.object_key} into a clean postgres: #{tables} tables" \
           "#{rows ? ", ~#{rows} rows" : ''}"
    backup.record_restore_success!(note: note)
    Result.new(status: "verified", tables: tables, rows: rows, detail: note)
  end

  # Demotes `status` too — see Backup#record_restore_failure!. A dump that
  # cannot restore is not a completed backup, and the row must not say it is.
  def fail!(detail)
    backup.record_restore_failure!(detail)
    Rails.logger.error("[RestoreVerify:#{backup.id}] #{detail}")
    Result.new(status: "failed", detail: detail)
  end

  # Nothing was tested, so nothing is claimed — `never_tested` stands.
  def skip(detail)
    Result.new(status: "skipped", detail: detail)
  end

  # --- plumbing ------------------------------------------------------------

  def dump_path = "/tmp/#{token}.sql.gz"

  def ok?(command)
    res = @ssh.execute_with_status(command)
    @last_error = (res[:stderr].presence || res[:output]).to_s.strip[0, 160] unless res[:success]
    res[:success]
  end

  def capture(command)
    res = @ssh.execute_with_status(command)
    res[:success] ? res[:output].to_s : ""
  end

  def esc(value) = Shellwords.escape(value.to_s)
end
