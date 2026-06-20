require "fileutils"

# Orchestrates a DatabasePull: dump the remote PostgreSQL database over SSH,
# download the dump to the Conductor host via SCP, and optionally restore it
# into a local Postgres database. Streams progress to the pull's log.
class DatabasePullService
  DUMP_DIR = Rails.root.join("tmp", "dumps")

  def initialize(pull, shell: LocalShell.new)
    @pull   = pull
    @server = pull.server
    @shell  = shell
  end

  def run
    @pull.start!
    log("=== Pulling database from #{@server.name} (#{@server.ip_address}) ===\n")

    ssh = SshConnection.new(@server)
    remote_path = "/tmp/conductor-pull-#{@pull.id}-#{timestamp}.dump"

    # 1. Dump on the remote box.
    log("\n[1/#{steps}] Dumping remote database (pg_dump -Fc)...\n")
    result = ssh.execute_with_status(remote_dump_command(remote_path))
    log(result[:output].to_s) if result[:output].present?
    return fail!("Remote dump failed (exit #{result[:exit_code]})") unless result[:success]

    ssh.execute("stat -c%s #{remote_path} 2>/dev/null || stat -f%z #{remote_path}")
    size = ssh.output.to_s.strip.to_i

    # 2. Download to the Conductor host.
    FileUtils.mkdir_p(DUMP_DIR)
    local_path = DUMP_DIR.join(File.basename(remote_path)).to_s
    log("\n[2/#{steps}] Downloading dump to #{local_path}...\n")
    return fail!("Download failed: #{ssh.error}") unless ssh.download(remote_path, local_path)

    @pull.update_columns(local_dump_path: local_path, size_bytes: size)
    log("Downloaded #{@pull.formatted_size}.\n")

    # 3. Remove the remote temp dump.
    ssh.execute("rm -f #{remote_path}")

    # 4. Optional local restore.
    if @pull.restore?
      log("\n[3/#{steps}] Restoring into local database '#{@pull.restore_target}'...\n")
      return fail!("Local restore failed") unless restore_local(local_path)
    end

    log("\n=== Done ===\n")
    @pull.finish!(success: true)
    true
  rescue => e
    fail!("Unexpected error: #{e.message}")
  end

  private

  def steps = @pull.restore? ? 3 : 2

  # When an env file is configured (e.g. Hatchbox's .asdf-vars) source it so
  # $DATABASE_URL is populated, then dump in custom format without owner/acl.
  def remote_dump_command(remote_path)
    var = @pull.source_database_url_var.presence || "DATABASE_URL"
    prefix =
      if @pull.source_env_file.present?
        "set -a; . #{shellesc(@pull.source_env_file)}; set +a; "
      else
        ""
      end
    %(#{prefix}pg_dump -Fc --no-owner --no-acl "$#{var}" -f #{remote_path})
  end

  def restore_local(local_path)
    target = @pull.restore_target
    # dropdb/createdb must succeed; pg_restore may exit non-zero on benign
    # warnings (e.g. missing roles) so its status is logged but not fatal.
    [
      { cmd: ["dropdb", "--if-exists", target], fatal: true },
      { cmd: ["createdb", target], fatal: true },
      { cmd: ["pg_restore", "--no-owner", "--no-acl", "-d", target, local_path], fatal: false }
    ].each do |step|
      res = @shell.run(*step[:cmd]) { |line| log("#{line}\n") }
      next if res.success?

      if step[:fatal]
        log("Command failed (exit #{res.exit_code}): #{step[:cmd].join(' ')}\n")
        return false
      else
        log("pg_restore finished with warnings (exit #{res.exit_code}).\n")
      end
    end
    true
  end

  def timestamp = Time.current.strftime("%Y%m%d%H%M%S")

  def shellesc(str) = "'#{str.to_s.gsub("'", "'\\\\''")}'"

  def log(line) = @pull.append_log(line)

  def fail!(msg)
    log("\n=== FAILED: #{msg} ===\n")
    @pull.finish!(success: false)
    false
  end
end
