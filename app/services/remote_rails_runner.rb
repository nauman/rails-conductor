require "base64"
require "shellwords"

# Runs a one-off Rails command inside an app's RUNNING container on its server,
# over SSH — the non-interactive equivalent of `kamal console`. Two entry points:
#
#   run(script)     — arbitrary Ruby via `bin/rails runner -`. The script is
#                     base64-encoded so quotes/heredocs/newlines survive the
#                     shell + SSH round-trip untouched.
#   run_task(task)  — a bare rails/rake task name (e.g. "db:migrate:status").
#
# The container is resolved the same way logs/status do: a kamal app matches any
# service candidate on the `service` label; a docker app matches its
# conductor-<slug> container by name. (Native apps have no container — callers
# gate those out.)
#
# Scripts can return a structured result by printing `MARKER + <json>` on one
# line; callers read it with `.payload`. This is how Conductor introspects and
# mutates a fleet app (Active Storage, ad-hoc runner calls) without shipping code
# into the repo.
class RemoteRailsRunner
  MARKER = "__CONDUCTOR_JSON__".freeze

  Result = Struct.new(:ok, :output, :exit_code, keyword_init: true) do
    def ok? = ok

    # The JSON object the script printed after MARKER, or nil if none/!ok.
    def payload
      return @payload if defined?(@payload)
      line = output.to_s.lines.reverse.find { |l| l.include?(MARKER) }
      @payload = line ? (JSON.parse(line.split(MARKER, 2).last.strip) rescue nil) : nil
    end
  end

  def initialize(app, ssh: nil)
    @app = app
    @ssh = ssh || SshConnection.new(app.server)
  end

  # The shell command for arbitrary Ruby: resolve the running container, decode
  # the script on stdin, feed it to `bin/rails runner -`. Exit 3 (+ a clear
  # message) if no container is running.
  def command(script)
    b64 = Base64.strict_encode64(script)
    wrap("echo #{b64} | base64 -d | docker exec -i \"$cid\" bin/rails runner - 2>&1")
  end

  # The shell command for a bare rails/rake task (validated by the caller).
  def task_command(task)
    wrap("docker exec \"$cid\" bin/rails #{task} 2>&1")
  end

  # ALWAYS the docker path, never kamal — arbitrary Ruby is delivered by a PIPELINE,
  # and kamal cannot carry one.
  #
  # `kamal app exec` renders `docker exec <container> <cmd>` and hands the whole
  # string to a shell ON THE HOST, so the pipes split there: `echo` runs inside the
  # container and `base64 -d | bin/rails runner -` runs on the host, where bin/rails
  # does not exist. The failure is `bash: line 1: bin/rails: No such file or
  # directory`, exit 127.
  #
  # The docker path builds the same pipeline the other way round — it pipes on the
  # host INTO `docker exec -i`, so the script arrives on the container's stdin, which
  # is correct and is what this ran on for months.
  #
  # This looked like a regression because eligibility, not the command, changed:
  # KamalOps becomes available once a checkout exists, and a DEPLOY creates the
  # checkout. So an app silently moved from the working path to the broken one the
  # first time it was deployed from this container. `run_task` keeps the kamal path,
  # because a bare `bin/rails <task>` carries no pipeline and genuinely benefits from
  # kamal resolving the live release.
  def run(script)
    exec(command(script))
  end

  def run_task(task)
    return kamal_exec("bin/rails #{task}") if kamal_ops?

    exec(task_command(task))
  end

  private

  def exec(cmd)
    res = @ssh.execute_with_status(cmd)
    Result.new(ok: res[:success], output: res[:output].to_s, exit_code: res[:exit_code])
  end

  # Kamal apps use Kamal's live-release resolver. This keeps runner behavior
  # aligned with logs/console and avoids guessed docker container names.
  def kamal_exec(command)
    result = kamal_ops.exec(command)
    # A bare `ok: false` with no output is the least useful failure available: the
    # caller cannot tell a broken command from a broken harness.
    Result.new(ok: result.ok?, output: result.output.presence || result.error.to_s, exit_code: result.ok? ? 0 : 1)
  end

  # Kamal only when kamal can actually ANSWER. KamalOps exists to be asked — its
  # #available? is the whole point, and skipping it broke every runner call for
  # every kamal app in production: the deployed container carries no kamal
  # checkout, so each call returned ok:false with empty output while the docker
  # path beside it worked. Asking, then falling back, is the documented contract.
  def kamal_ops? = @app.kamal? && @app.server.present? && kamal_ops.available?

  def kamal_ops = @kamal_ops ||= KamalOps.new(@app)

  # Prefix an in-container command with container resolution + a NO_CONTAINER guard.
  def wrap(inner)
    <<~SH.strip
      #{resolve_cid}
      if [ -z "$cid" ]; then echo "NO_CONTAINER (#{container_hint})"; exit 3; fi
      #{inner}
    SH
  end

  # kamal: match any service candidate on the `service` label (the service name
  # isn't always the slug). docker: match the conductor-<slug> container by name
  # (slug is a parameterized, shell-safe token).
  def resolve_cid
    if @app.kamal?
      cands = @app.kamal_service_candidates.map { |c| Shellwords.escape(c) }.join(" ")
      %(cid=""; for s in #{cands}; do cid=$(docker ps -q -f "label=service=$s" -f status=running | head -n1); [ -n "$cid" ] && break; done)
    else
      # Label first, legacy fixed name as fallback — a zero-downtime deploy runs
      # the app as app-<id>-r<rev>-<sha>, which the fixed name never matches.
      @app.resolve_container_shell.chomp("; ") + %(; true)
    end
  end

  # Interpolated into a shell `echo`, so it must not carry shell metacharacters —
  # a slug is now format-constrained, but this is the second line of defence and
  # costs nothing.
  def container_hint
    raw = if @app.kamal?
            "service: #{@app.kamal_service_candidates.join(', ')}"
    else
            "container: #{@app.container_name}"
    end
    raw.gsub(/[^a-zA-Z0-9 ,.:_-]/, "")
  end
end
