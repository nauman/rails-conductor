# Enforce a backup's retention window in the bucket.
#
# `retention_days` was shown on every backup ("14 days") and enforced by nothing:
# objects accumulated forever. This is the piece that keeps that promise.
#
# It is also the ONLY part of the backup system that deletes data, so it is built
# to refuse rather than to guess:
#
#   - it only ever looks under this backup's own prefix (`<slug>/`), which matters
#     because thirteen apps share one bucket;
#   - it only deletes objects that look like dumps (`.sql.gz`);
#   - it NEVER deletes the newest object, however old it is — an app that stopped
#     backing up has only stale objects, and honouring the window literally would
#     make retention delete the last copy of its database;
#   - a listing that fails prunes nothing. Reading an error as "the bucket is
#     empty" is the same fault that let failed uploads record as successes.
class BackupRetention
  Result = Struct.new(:ok, :deleted, :kept, :error, keyword_init: true) do
    def ok? = ok
  end

  DUMP = /\.sql\.gz\z/

  def initialize(backup, ssh: nil)
    @backup = backup
    @ssh = ssh || SshConnection.new(backup.server || backup.app&.server)
  end

  def prune!
    days = @backup.retention_days.to_i
    return Result.new(ok: true, deleted: 0, kept: 0) unless days.positive?

    objects = list
    return Result.new(ok: false, deleted: 0, kept: 0, error: @error) if objects.nil?

    cutoff = days.days.ago
    # Sort newest first so the survivor rule is simply "never the head".
    sorted = objects.sort_by { |o| o[:at] }.reverse
    doomed = sorted.drop(1).select { |o| o[:at] < cutoff }

    doomed.each { |o| delete(o[:key]) }

    Result.new(ok: true, deleted: doomed.size, kept: sorted.size - doomed.size)
  end

  private

  attr_reader :backup

  def prefix = "#{backup.object_prefix}/"

  # `s3api list-objects-v2` rather than `s3 ls`, because it gives an ISO
  # timestamp per key instead of a locale-shaped date column to re-parse.
  def list
    res = @ssh.execute_with_status(list_command)
    unless res[:success]
      @error = "could not list #{prefix}: #{res[:stderr].presence || res[:output]}"
      return nil
    end

    res[:output].to_s.lines.filter_map do |line|
      key, stamp = line.strip.split(/\s+/, 2)
      next if key.blank? || stamp.blank?
      # Belt and braces: the query is prefix-scoped, but a shared bucket means a
      # wrong prefix would delete another app's backups.
      next unless key.start_with?(prefix) && key.match?(DUMP)

      { key: key, at: Time.parse(stamp) }
    rescue ArgumentError
      next # an unparseable timestamp is not a licence to delete
    end
  end

  def list_command
    with_env([
      "aws", "s3api", "list-objects-v2",
      "--bucket", esc(backup.bucket_name),
      "--prefix", esc(prefix),
      "--query", esc("Contents[].[Key,LastModified]"),
      "--output", "text"
    ])
  end

  def delete(key)
    @ssh.execute_with_status(with_env([
      "aws", "s3", "rm", esc("s3://#{backup.bucket_name}/#{key}")
    ]))
  end

  def with_env(cmd)
    vendor = BackupVendors[backup.provider]
    cred = backup.credential
    env = [
      "AWS_ACCESS_KEY_ID=#{esc(cred.api_key)}",
      "AWS_SECRET_ACCESS_KEY=#{esc(cred.api_secret)}",
      "AWS_DEFAULT_REGION=#{esc(vendor.region(cred))}"
    ]
    cmd += [ "--endpoint-url", esc(vendor.endpoint(cred)) ] if vendor.endpoint(cred).present?
    "#{env.join(' ')} #{cmd.join(' ')}"
  end

  def esc(value) = Shellwords.escape(value.to_s)
end
