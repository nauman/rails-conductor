# Migrates a fleet app's Active Storage blobs from one service to another
# (e.g. local -> cloudflare_r2): uploads each blob's file to the target service
# and repoints service_name. Idempotent (skips upload if already present) and
# chunked (processes up to `limit` migratable blobs per call, reporting how many
# migratable blobs remain) so a large set can be drained across calls without a
# single long-running SSH exec. Blobs whose SOURCE file is missing are counted
# and left in place (variants regenerate from the migrated original on demand).
# Runs in the app's container via RemoteRailsRunner. Mutating.
class ActiveStorageR2Migrator
  SERVICE_RE = /\A[a-z0-9_]+\z/i
  DEFAULT_LIMIT = 1000

  Result = Struct.new(:ok, :data, :error, keyword_init: true) do
    def ok? = ok
  end

  BODY = <<~'RUBY'
    require "json"
    from = "__FROM__"; to = "__TO__"; limit = __LIMIT__
    src = ActiveStorage::Blob.services.fetch(from.to_sym)
    dst = ActiveStorage::Blob.services.fetch(to.to_sym)
    migrated = 0; missing = 0; errors = 0
    ActiveStorage::Blob.where(service_name: from).find_each do |blob|
      break if migrated >= limit
      unless (src.exist?(blob.key) rescue false)
        missing += 1
        next
      end
      begin
        dst.upload(blob.key, StringIO.new(src.download(blob.key)), checksum: blob.checksum, filename: blob.filename, content_type: blob.content_type) unless dst.exist?(blob.key)
        blob.update_columns(service_name: to)
        migrated += 1
      rescue => _e
        errors += 1
      end
    end
    remaining = 0
    ActiveStorage::Blob.where(service_name: from).find_each { |b| remaining += 1 if (src.exist?(b.key) rescue false) }
    puts "__MARKER__" + {
      from: from, to: to, migrated: migrated, missing_source: missing,
      errors: errors, remaining_migratable: remaining
    }.to_json
  RUBY

  def initialize(app, runner: nil)
    @app = app
    @runner = runner || RemoteRailsRunner.new(app)
  end

  # from/to are validated against SERVICE_RE before substitution (they land in
  # the runner script, so they must be safe identifiers, not arbitrary strings).
  def script(from:, to:, limit:)
    BODY
      .sub("__FROM__", from)
      .sub("__TO__", to)
      .sub("__LIMIT__", limit.to_i.to_s)
      .sub("__MARKER__", RemoteRailsRunner::MARKER)
  end

  def call(from: "local", to: "cloudflare_r2", limit: DEFAULT_LIMIT)
    return Result.new(ok: false, error: "Invalid service name.") unless from.to_s.match?(SERVICE_RE) && to.to_s.match?(SERVICE_RE)

    res = @runner.run(script(from: from, to: to, limit: limit))
    payload = res.payload
    return Result.new(ok: true, data: payload) if payload

    Result.new(ok: false, error: migrate_error(res))
  end

  private

  def migrate_error(res)
    return "No running container found for #{@app.name} on #{@app.server&.name}." if res.output.to_s.include?("NO_CONTAINER")
    "Active Storage migration failed: #{res.output.to_s.lines.last(3).join.strip.presence || 'no output'}"
  end
end
