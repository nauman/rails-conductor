require "base64"
require "shellwords"

# Runs a Ruby script via `bin/rails runner -` inside an app's RUNNING container
# on its server, over SSH. Resolves the container the same way status/logs do
# (match any kamal service candidate on the `service` label). The script is
# base64-encoded so arbitrary Ruby (quotes, heredocs, newlines) survives the
# shell + SSH round-trip untouched.
#
# Scripts communicate a structured result by printing `MARKER + <json>` on one
# line; callers parse it with `.payload`. This is how Conductor introspects and
# mutates a fleet app's Active Storage without shipping code into the repo.
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

  # The shell command: find the running container, decode the script on stdin,
  # feed it to `bin/rails runner -`. Exit 3 (and a clear message) if no container.
  def command(script)
    b64 = Base64.strict_encode64(script)
    cands = @app.kamal_service_candidates.map { |c| Shellwords.escape(c) }.join(" ")
    names = @app.kamal_service_candidates.join(", ")
    <<~SH.strip
      cid=""; for s in #{cands}; do cid=$(docker ps -q -f "label=service=$s" -f status=running | head -n1); [ -n "$cid" ] && break; done
      if [ -z "$cid" ]; then echo "NO_CONTAINER (service: #{names})"; exit 3; fi
      echo #{b64} | base64 -d | docker exec -i "$cid" bin/rails runner - 2>&1
    SH
  end

  def run(script)
    res = @ssh.execute_with_status(command(script))
    Result.new(ok: res[:success], output: res[:output].to_s, exit_code: res[:exit_code])
  end
end
