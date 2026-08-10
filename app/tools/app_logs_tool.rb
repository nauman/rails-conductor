# What the RUNNING app said — as opposed to `logs` (Conductor's own record of a
# script run) or `deployment` (a deploy transcript). Without this, diagnosing a
# live incident means dropping to SSH, which app-scoped agents are guarded from,
# and Conductor's promise of per-app visibility stops at its own bookkeeping.
#
# Reports `covers_from` deliberately: a container log is a rotating buffer, so a
# window that returns nothing may have been overwritten rather than been quiet.
# Absent evidence is not evidence, and a reader must be able to tell the two apart.
class AppLogsTool
  include ActorScoped

  DEFAULT_TAIL = 200
  MAX_TAIL = 2000

  def initialize(user:, runner: nil)
    @user = user
    @runner = runner
  end

  def call(input)
    app = find_app(input) or return Result.fail("App not found. Pass app_id or app_name.")
    server = app.server or return Result.fail("#{app.name} has no server attached, so it has no container to read logs from.")

    raw = run(server, command_for(app, tail_for(input)))
    return Result.fail("No running container found for #{app.name} on #{server.name}.") if raw.to_s.include?(NO_CONTAINER)

    container, log = split(raw)
    Result.ok(payload(app, server, container, log))
  end

  private

  NO_CONTAINER = "__NO_CONTAINER__".freeze
  SEPARATOR = "---".freeze

  def payload(app, server, container, log)
    {
      app: app.name,
      server: server.name,
      container: container,
      lines: log.lines.size,
      # The oldest line still retained. If this is later than the moment you care
      # about, the evidence is gone — raise the container's log retention.
      covers_from: timestamp_of(log.lines.first),
      log: log
    }
  end

  # One round trip: resolve the container, then tail it. Kamal labels its web
  # containers `role=web`; a plain-docker deploy may not, so fall back to a
  # name match on the app's slug.
  def command_for(app, tail)
    slug = app.slug.to_s
    <<~SH.strip
      C=$(docker ps --format '{{.Names}}' --filter label=service=#{esc(slug)} --filter label=role=web | head -1)
      [ -z "$C" ] && C=$(docker ps --format '{{.Names}}' | grep -E '^#{esc(slug)}[-_]' | head -1)
      [ -z "$C" ] && { echo #{NO_CONTAINER}; exit 0; }
      echo "$C"; echo #{SEPARATOR}; docker logs --timestamps --tail #{tail} "$C" 2>&1
    SH
  end

  def split(raw)
    head, _, tail = raw.to_s.partition("\n#{SEPARATOR}\n")
    [ head.strip, tail.to_s ]
  end

  def timestamp_of(line)
    line.to_s[/\A\S+/]
  end

  def tail_for(input)
    tail = input["tail"].to_i
    tail = DEFAULT_TAIL unless tail.positive?
    [ tail, MAX_TAIL ].min
  end

  def run(server, command)
    return @runner.call(command) if @runner

    SshConnection.new(server).execute(command)
  end

  def esc(value) = value.gsub(/[^a-zA-Z0-9_\-.]/, "")
end
