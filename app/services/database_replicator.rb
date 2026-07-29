require "shellwords"

# Replicates a Postgres database from a source server to a target server by
# staging through S3-compatible object storage (R2 by default) — the same path
# Conductor already uses for backups. On the SOURCE: `pg_dump | gzip` → upload.
# On the TARGET: download → `gunzip | psql`. Mirrors DatabaseBackup /
# DatabaseRestore command-building, reusing the BackupVendors registry for the
# endpoint/region. Used by the app-transfer pipeline (spec 26, Part 3) to move a
# database's data as part of a cold cut-over.
#
# Both SSH connections are injectable for tests; the credential is duck-typed
# (api_key / api_secret / account_id / region), so any Credential works.
class DatabaseReplicator
  class Error < StandardError; end

  attr_reader :log

  def initialize(source_server:, source_url:, target_server:, target_url:,
                 credential:, bucket:, object_key:, provider: "cloudflare_r2",
                 source_ssh: nil, target_ssh: nil,
                 network: nil, pg_image: PostgresContainerClient::DEFAULT_IMAGE)
    @source_server = source_server
    @source_url    = source_url
    @target_server = target_server
    @target_url    = target_url
    @credential    = credential
    @bucket        = bucket
    @object_key    = object_key
    @provider      = provider
    @source_ssh    = source_ssh
    @target_ssh    = target_ssh
    # When set, run the Postgres client (pg_dump/psql) INSIDE this Docker network
    # rather than on the host. A colocated dedicated DB (`<app>-db`) is reachable
    # only by container DNS on the app's network — the host can't resolve it — so
    # host-run psql fails with "could not translate host name". Running the client
    # in a throwaway container on that network makes both the shared source and the
    # dedicated target resolve; using the DB's own image also matches client to
    # server version (pg_dump refuses a server newer than the client).
    @network       = network.presence
    @pg_image      = pg_image
    @log = +""
  end

  def run!
    validate!
    dump_and_upload!
    download_and_restore!
    true
  end

  private

  def validate!
    raise Error, "no object-storage credential" unless @credential
    raise Error, "no bucket" if @bucket.blank?
    raise Error, "no object_key" if @object_key.blank?
    raise Error, "missing source/target database URL" if @source_url.blank? || @target_url.blank?
    raise Error, "unsupported storage provider: #{@provider}" unless vendor
  end

  def dump_and_upload!
    tmp = remote_tmp
    run_on(source_ssh, "#{pg_dump_cmd(@source_url)} | gzip > #{tmp}", "dump source database")
    run_on(source_ssh, "#{aws_env} aws s3 cp #{tmp} s3://#{@bucket}/#{@object_key}#{endpoint_flag}",
           "upload dump to #{@provider}")
    source_ssh.execute_with_status("rm -f #{tmp}")
  end

  def download_and_restore!
    tmp = remote_tmp
    run_on(target_ssh, "#{aws_env} aws s3 cp s3://#{@bucket}/#{@object_key} #{tmp}#{endpoint_flag}",
           "download dump on target")
    run_on(target_ssh, "gunzip -c #{tmp} | #{psql_cmd(@target_url)}", "restore into target database")
    target_ssh.execute_with_status("rm -f #{tmp}")
  end

  # pg_dump reads from its args (no stdin); psql consumes the gunzipped dump on
  # stdin, so its container needs `-i`. Both stream to/from the host pipe, so the
  # dump file, gzip/gunzip and aws all stay on the host — only the DB dialogue
  # moves onto the network.
  def pg_dump_cmd(url) = "#{docker_pg} pg_dump #{esc(url)}".strip
  def psql_cmd(url)    = "#{docker_pg(interactive: true)} psql #{esc(url)}".strip

  # The `docker run` prefix that puts a one-shot client on the app's network, or
  # "" to fall back to the host binary when no network is configured (tests, and
  # any host-reachable DB).
  def docker_pg(interactive: false)
    return "" if @network.blank?

    flags = interactive ? "--rm -i" : "--rm"
    "docker run #{flags} --network #{esc(@network)} #{esc(@pg_image)}"
  end

  def run_on(ssh, command, label)
    append_log("→ #{label}")
    result = ssh.execute_with_status(command)
    return if result[:success]

    raise Error, "#{label} failed: #{ssh.error.presence || result[:stderr].presence || 'command failed'}"
  end

  def vendor = BackupVendors[@provider]

  def aws_env
    "AWS_ACCESS_KEY_ID=#{@credential.api_key} AWS_SECRET_ACCESS_KEY=#{@credential.api_secret} " \
      "AWS_DEFAULT_REGION=#{vendor.region(@credential)}"
  end

  def endpoint_flag
    ep = vendor.endpoint(@credential)
    ep.present? ? " --endpoint-url #{ep}" : ""
  end

  def source_ssh = @source_ssh ||= SshConnection.new(@source_server)
  def target_ssh = @target_ssh ||= SshConnection.new(@target_server)
  def remote_tmp = "/tmp/conductor-repl-#{@object_key.to_s.tr('/', '_')}.sql.gz"
  def esc(value) = Shellwords.escape(value.to_s)
  def append_log(line) = (@log << "#{line}\n")
end
