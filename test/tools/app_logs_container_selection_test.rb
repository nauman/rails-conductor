require "test_helper"

# RENDER THE SELECTION SHELL AND RUN IT against a fake `docker ps`.
#
# The defect this pins was reported from production: an operator chasing a failed
# WEB request on a multi-container app was handed the SCHEDULER container — job
# output only, no web requests — with no way to ask for another and nothing
# saying a web container existed. The old selection was "role=web label, else ANY container
# whose name starts with the slug, head -1", and a plain-docker deploy carries no
# kamal labels, so it returned whatever docker listed first.
class AppLogsContainerSelectionTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "logs@example.com")
    @org = Organization.create_for(user, name: "Logs")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9", ssh_user: "deploy")
    @app = @org.apps.create!(name: "Acme", slug: "acme", server: @server, deploy_method: "kamal")
  end

  # `docker ps` lists newest first, which is why the scheduler won. The fake
  # reproduces that ordering deliberately.
  def with_fake_docker(names:, labelled: false)
    in_a_sandbox do |dir|
      bin = File.join(dir, "bin")
      FileUtils.mkdir_p(bin)
      listing = names.join("\n")
      File.write(File.join(bin, "docker"), <<~SH)
        #!/bin/sh
        if [ "$1" = "ps" ]; then
          case "$*" in
            *"label=role="*)
              #{labelled ? 'role=$(printf "%s" "$*" | sed -n "s/.*label=role=\\\\([a-z]*\\\\).*/\\\\1/p"); printf "%s\\\\n" "#{listing}" | grep -- "-$role$" || true' : 'true'}
              ;;
            *"label=service="*) #{labelled ? %(printf '%s\\n' "#{listing}") : "true"} ;;
            *) printf '%s\\n' "#{listing}" ;;
          esac
          exit 0
        fi
        if [ "$1" = "logs" ]; then
          shift
          for a in "$@"; do last="$a"; done
          echo "LOGS FROM $last"
          exit 0
        fi
        exit 0
      SH
      FileUtils.chmod(0o755, File.join(bin, "docker"))
      yield bin, dir
    end
  end

  def render(role: nil, tail: 50)
    AppLogsTool.new(user: User.first).send(:command_for, @app, tail, role: role)
  end

  # The reported bug, as a test: scheduler listed first, web must still win.
  test "prefers the web container even when another is listed first" do
    with_fake_docker(names: %w[acme-scheduler acme-queue acme-web]) do |bin, _dir|
      out, _err, status = run_shell("PATH=#{bin}:$PATH sh -c #{Shellwords.escape(render)}")

      assert_equal 0, status
      assert_equal "acme-web", out.lines.first.strip,
                   "an operator asking for logs during an incident means the thing serving requests"
      assert_includes out, "LOGS FROM acme-web"
    end
  end

  test "a named role reads that container" do
    with_fake_docker(names: %w[acme-scheduler acme-queue acme-web]) do |bin, _dir|
      out, _err, _status = run_shell("PATH=#{bin}:$PATH sh -c #{Shellwords.escape(render(role: 'queue'))}")

      assert_equal "acme-queue", out.lines.first.strip
      assert_includes out, "LOGS FROM acme-queue"
    end
  end

  # Being shown one container while three run is how "no errors in the logs" gets
  # concluded from the wrong one.
  test "every running container is reported, not just the one read" do
    with_fake_docker(names: %w[acme-scheduler acme-queue acme-web]) do |bin, _dir|
      out, _err, _status = run_shell("PATH=#{bin}:$PATH sh -c #{Shellwords.escape(render)}")

      %w[acme-web acme-queue acme-scheduler].each do |name|
        assert_includes out, name, "#{name} should appear in the container listing"
      end
    end
  end

  # Falling back to a different container would let the reader believe they were
  # looking at the role they asked for.
  test "a role that is not running reports what is, rather than reading another" do
    with_fake_docker(names: %w[acme-scheduler acme-queue]) do |bin, _dir|
      out, _err, _status = run_shell("PATH=#{bin}:$PATH sh -c #{Shellwords.escape(render)}")

      assert_includes out, "__NO_MATCH__", "no web container means no read, not a substitute"
      assert_includes out, "acme-scheduler"
      assert_not_includes out, "LOGS FROM", "nothing may be tailed when the requested role is absent"
    end
  end

  test "no containers at all is distinct from a wrong role" do
    with_fake_docker(names: []) do |bin, _dir|
      out, _err, _status = run_shell("PATH=#{bin}:$PATH sh -c #{Shellwords.escape(render)}")

      assert_includes out, "__NO_CONTAINER__"
      assert_not_includes out, "__NO_MATCH__"
    end
  end

  # Kamal labels its containers; the label must still take precedence.
  test "the kamal role label is preferred over the name" do
    with_fake_docker(names: %w[acme-web acme-queue], labelled: true) do |bin, _dir|
      out, _err, _status = run_shell("PATH=#{bin}:$PATH sh -c #{Shellwords.escape(render)}")

      assert_equal "acme-web", out.lines.first.strip
    end
  end
  # The kamal path dropped `role` on the floor, so the MCP schema advertised a
  # capability that did nothing for every kamal-deployed app. Asserted on the
  # rendered command, because that is where the flag either is or is not.
  test "the kamal path passes the requested role through as --roles" do
    cmd = KamalCommand.new
    assert_includes cmd.app_logs(lines: 50, role: "queue"), "--roles queue"
    assert_includes cmd.app_logs(lines: 50), "app logs -n 50"
    assert_not_includes cmd.app_logs(lines: 50), "--roles",
                        "no role asked for means kamal's own default, not a guess"
  end
end
