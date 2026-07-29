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

  def run(script)
    exec(command(script))
  end

  def run_task(task)
    exec(task_command(task))
  end

  private

  def exec(cmd)
    res = @ssh.execute_with_status(cmd)
    Result.new(ok: res[:success], output: res[:output].to_s, exit_code: res[:exit_code])
  end

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
      %(cid=$(docker ps -q -f "name=^/#{@app.container_name}$" -f status=running | head -n1))
    end
  end

  def container_hint
    @app.kamal? ? "service: #{@app.kamal_service_candidates.join(', ')}" : "container: #{@app.container_name}"
  end
end
