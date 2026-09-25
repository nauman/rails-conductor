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

  def initialize(user:, runner: nil, kamal_ops: nil)
    @user = user
    @runner = runner
    @kamal_ops = kamal_ops
  end

  def call(input)
    app = find_app(input) or return Result.fail("App not found. Pass app_id or app_name.")
    server = app.server or return Result.fail("#{app.name} has no server attached, so it has no container to read logs from.")

    # Kamal is the ops harness where the app has a real kamal config (ADR 0003/0004):
    # it knows the roles, the destination overlay and which release is current,
    # where a hand-built `docker logs` only knows a container name we guessed —
    # which is how an ops read ends up tailing a `_replaced_` leftover.
    ops = kamal_ops_for(app)
    if ops.available?
      # The kamal path used to drop `role` silently, so the parameter advertised
      # in the MCP schema did nothing for every kamal app — the schema described a
      # capability half the fleet did not have.
      result = ops.logs(tail: tail_for(input), role: input["role"].presence)
      return Result.fail(result.error) unless result.ok?

      return Result.ok(payload(app, server, "via kamal", result.output, via: "kamal"))
    end

    # Carry the reason kamal could not answer. Silence here is what let an agent
    # conclude "kamal cannot be used for this app" from a bare DNS failure.
    kamal_note = ops.unavailable_reason
    role = input["role"].presence
    raw = run(server, command_for(app, tail_for(input), role: role))
    return Result.fail("No running container found for #{app.name} on #{server.name}.") if raw.to_s.include?(NO_CONTAINER)

    # Asked for a role that is not running: name what IS, rather than silently
    # falling back to a different container and letting the reader believe they
    # are looking at the one they asked for.
    if raw.to_s.include?(NO_MATCH)
      running = raw.to_s.sub(NO_MATCH, "").split("\n").map(&:strip).reject(&:blank?)
      return Result.fail("No #{role || 'web'} container is running for #{app.name} on #{server.name}. " \
                         "Running: #{running.join(', ')}. Re-run with role: one of those.")
    end

    container, siblings, log = split(raw)
    payload = payload(app, server, container, log, via: "docker")
                .merge(kamal_unavailable: kamal_note, containers: siblings).compact

    # Say when there is more to read. A reader shown one container's logs has no
    # way to know three others exist, which is how "no errors in the logs" gets
    # concluded from the wrong container.
    if siblings.size > 1
      others = siblings - [ container ]
      payload[:note] = "Showing #{container}. Also running: #{others.join(', ')} — " \
                       "pass role: to read one of those (this app's containers are not kamal-labelled, " \
                       "so the role is matched on the container name)."
    end
    Result.ok(payload)
  end

  private

  NO_CONTAINER = "__NO_CONTAINER__".freeze
  NO_MATCH = "__NO_MATCH__".freeze
  CONTAINERS = "__CONTAINERS__".freeze
  SEPARATOR = "---".freeze
  REDACTION = "[REDACTED]".freeze

  # Application logs routinely carry credentials: a Bearer token in a header dump,
  # a DATABASE_URL in a boot error, an api_key in a query string. conductor_read is
  # callable by any read-scoped token, so raw log text would hand every such token
  # production secrets. Redaction is deliberately broad — a false positive costs a
  # reader one obscured value, a false negative leaks a live credential.
  # Pattern-based redaction is best-effort by nature — an unlabelled secret in an
  # unknown shape can always slip past. These cover the shapes a codex review
  # confirmed were leaking, and every value bound is 1+ rather than 6+ because a
  # short token is still a token.
  SECRET_PATTERNS = [
    # `Authorization: Bearer <token>` — the value follows whitespace, not a
    # delimiter, because the colon belongs to the header name.
    /(\b(?:bearer|basic)\s+)(\S+)/i,
    # Cookie / Set-Cookie: redact the whole value but keep the header name, so the
    # line stays readable. Cookies are session credentials.
    /^(\s*set-cookie\s*:\s*|\s*cookie\s*:\s*)(.+)$/i,
    # A JWT anywhere, labelled or not: three base64url segments.
    /\b(ey[A-Za-z0-9_-]{8,})\.([A-Za-z0-9_-]{6,})\.([A-Za-z0-9_-]{6,})/,
    # AWS access key ids are self-identifying.
    /\b((?:AKIA|ASIA|AGPA|AIDA)[A-Z0-9]{12,})/,
    # Bearer / token / key / secret / password as a labelled value.
    /((?:bearer|token|secret|password|passwd|api[_-]?key|access[_-]?key|master[_-]?key|authorization)["'\s]*[:=]\s*["']?)([^\s"'&,;]+)/i,
    # Credentials inside a connection string: scheme://user:secret@host
    %r{(://[^\s:/@]+:)([^\s@/]+)(@)},
    # Any *_KEY / *_TOKEN / *_SECRET / *_PASSWORD env assignment.
    /(\b[A-Z][A-Z0-9_]*(?:KEY|TOKEN|SECRET|PASSWORD)\s*[:=]\s*)([^\s"',;]+)/
  ].freeze

  # Patterns whose FIRST group is the secret itself rather than a label to keep
  # (a JWT and an AWS key id are self-identifying, so nothing precedes them).
  WHOLE_MATCH_PATTERNS = [ 2, 3 ].freeze

  def payload(app, server, container, log, via:)
    clean = redact(log)

    {
      app: app.name,
      server: server.name,
      container: container,
      # Which harness answered. "these are the logs" means something different
      # through kamal (release-aware) than through docker (name-guessed).
      via: via,
      lines: log.lines.size,
      # The oldest line still retained. If this is later than the moment you care
      # about, the evidence is gone — raise the container's log retention.
      covers_from: timestamp_of(log.lines.first),
      redacted: clean != log,
      log: clean
    }
  end

  def redact(log)
    SECRET_PATTERNS.each_with_index.reduce(log.to_s) do |text, (pattern, index)|
      text.gsub(pattern) do
        if WHOLE_MATCH_PATTERNS.include?(index)
          REDACTION # the match IS the secret — a JWT or an AWS key id
        else
          # Keep the label and any trailing delimiter; replace only the value.
          "#{Regexp.last_match(1)}#{REDACTION}#{Regexp.last_match(3)}"
        end
      end
    end
  end

  # One round trip: resolve the container, then tail it.
  #
  # THE BUG THIS REPLACES. The old selection was: containers labelled role=web,
  # else ANY container whose name starts with the slug, `head -1`. Kamal labels
  # its containers; a plain-docker deploy does not — so for an app deployed by its
  # own script the first branch matched nothing and the second returned whatever
  # `docker ps` happened to list first. An operator chasing a failed web request
  # on a multi-container app got the SCHEDULER container — job output only — with
  # no way to ask for another, and nothing saying a web container existed at all.
  #
  # Three changes: prefer web by NAME as well as by label; let the caller name a
  # role; and always report every container that matched, so a reader is never
  # shown one and left to assume it was the only one.
  def command_for(app, tail, role: nil)
    slug = app.slug.to_s
    wanted = role.presence
    <<~SH.strip
      ALL=$(docker ps --format '{{.Names}}' --filter label=service=#{esc(slug)})
      [ -z "$ALL" ] && ALL=$(docker ps --format '{{.Names}}' | grep -E '^#{esc(slug)}[-_]')
      [ -z "$ALL" ] && { echo #{NO_CONTAINER}; exit 0; }
      # A container kamal replaced during a failed or superseded boot can still be
      # RUNNING, and tailing one is reading a release nobody is served. Drop them
      # before choosing, not after — the old code chose first and never looked.
      ALL=$(printf '%s\n' "$ALL" | grep -v '_replaced_' || true)
      [ -z "$ALL" ] && { echo #{NO_CONTAINER}; exit 0; }
      #{selection_for(slug, wanted)}
      [ -z "$C" ] && { echo #{NO_MATCH}; echo "$ALL"; exit 0; }
      echo "$C"
      echo #{CONTAINERS}
      echo "$ALL"
      echo #{SEPARATOR}
      docker logs --timestamps --tail #{tail} "$C" 2>&1
    SH
  end


  # Label first (kamal sets it), then the conventional `<slug>-<role>` name that a
  # plain-docker deploy uses. Without a role, web is the default because a person
  # asking for "the logs" during an incident means the thing serving requests —
  # but it is a PREFERENCE, not an assumption: if no web container exists the
  # caller is told what does, rather than being handed an arbitrary one.
  def selection_for(slug, role)
    target = role || "web"
    <<~SH.strip
      # Intersected with $ALL so the label lookup inherits the _replaced_ filter.
      # Without that a labelled leftover wins here and the filter above is moot.
      LABELLED=$(docker ps --format '{{.Names}}' --filter label=service=#{esc(slug)} --filter label=role=#{esc(target)})
      # POSIX intersection. `grep -Fxf <(...)` reads naturally and is a BASHISM —
      # remote commands run through `sh -c`, where process substitution is a
      # syntax error, so it would have failed only in production.
      C=""
      for n in $LABELLED; do
        if printf '%s\n' "$ALL" | grep -qxF "$n"; then C="$n"; break; fi
      done
      [ -z "$C" ] && C=$(printf '%s\n' "$ALL" | grep -E '(^|[-_])#{esc_word(target)}$' | head -1)
    SH
  end

  # container name, the full container list, then the log body.
  def split(raw)
    head, _, tail = raw.to_s.partition("\n#{SEPARATOR}\n")
    name, _, listing = head.to_s.partition("\n#{CONTAINERS}\n")
    [ name.strip, listing.split("\n").map(&:strip).reject(&:blank?), tail.to_s ]
  end

  def timestamp_of(line)
    line.to_s[/\A\S+/]
  end

  def tail_for(input)
    tail = input["tail"].to_i
    tail = DEFAULT_TAIL unless tail.positive?
    [ tail, MAX_TAIL ].min
  end

  def kamal_ops_for(app)
    @kamal_ops || KamalOps.new(app)
  end

  def run(server, command)
    return @runner.call(command) if @runner

    SshConnection.new(server).execute(command)
  end

  def esc(value) = value.gsub(/[^a-zA-Z0-9_\-.]/, "")

  # esc() keeps `.`, which is a regex metacharacter — harmless in a docker filter
  # value, not harmless in the grep patterns above, where `role: "a.b"` would match
  # a container it should not. A role is a word, so a dot is simply not allowed.
  def esc_word(value) = value.to_s.gsub(/[^a-zA-Z0-9_\-]/, "")
end
