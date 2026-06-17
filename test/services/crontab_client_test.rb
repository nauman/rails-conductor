require "test_helper"
require "base64"

class CrontabClientTest < ActiveSupport::TestCase
  FakeSsh = Struct.new(:responses, :error) do
    attr_reader :commands

    def initialize(responses)
      super(responses, nil)
      @commands = []
    end

    def execute_with_status(command)
      @commands << command
      response = responses.shift || {}
      self.error = response[:error]
      {
        success: response.fetch(:success, true),
        exit_code: response.fetch(:success, true) ? 0 : 1,
        stdout: response[:stdout].to_s,
        stderr: response[:stderr].to_s,
        output: response[:stdout].to_s
      }
    end
  end

  # The new crontab is base64-encoded into the write command; decode it back.
  def written_crontab(command)
    Base64.decode64(command[/echo (\S+) \|/, 1].to_s)
  end

  def build_server
    server = Server.new(name: "edge-1", status: "online", ip_address: "203.0.113.10", ssh_user: "deploy")
    server.define_singleton_method(:ssh_configured?) { true }
    server
  end

  test "read_crontab returns the raw crontab and never fails on an empty crontab" do
    ssh = FakeSsh.new([ { stdout: "" } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    assert_equal "", client.read_crontab
    assert_includes ssh.commands.first, "crontab -l"
    assert_includes ssh.commands.first, "|| true"
  end

  test "upsert_job appends a managed block and preserves foreign lines" do
    existing = "# hand-written\n0 0 * * * /usr/local/bin/manual-backup\n"
    ssh = FakeSsh.new([ { stdout: existing }, { stdout: "" } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    client.upsert_job(id: "cron-7", name: "Nightly audit", cron_expression: "0 3 * * *", command: "/usr/bin/server-audit")

    written = written_crontab(ssh.commands.last)
    assert_includes written, "0 0 * * * /usr/local/bin/manual-backup"
    assert_includes written, "# hand-written"
    assert_includes written, "# >>> conductor:cron-7 Nightly audit"
    assert_includes written, "0 3 * * * /usr/bin/server-audit"
    assert_includes written, "# <<< conductor:cron-7"
  end

  test "upsert_job replaces an existing managed block in place" do
    existing = [
      "# >>> conductor:cron-7 Old name",
      "0 1 * * * /old/command",
      "# <<< conductor:cron-7"
    ].join("\n") + "\n"
    ssh = FakeSsh.new([ { stdout: existing }, { stdout: "" } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    client.upsert_job(id: "cron-7", name: "New name", cron_expression: "0 2 * * *", command: "/new/command")

    written = written_crontab(ssh.commands.last)
    refute_includes written, "/old/command"
    refute_includes written, "Old name"
    assert_includes written, "0 2 * * * /new/command"
    assert_equal 1, written.scan("# >>> conductor:cron-7").size
  end

  test "upsert_job comments out the command for a disabled job" do
    ssh = FakeSsh.new([ { stdout: "" }, { stdout: "" } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    client.upsert_job(id: "cron-9", name: "Paused", cron_expression: "0 5 * * *", command: "/bin/thing", enabled: false)

    written = written_crontab(ssh.commands.last)
    assert_includes written, "# 0 5 * * * /bin/thing"
  end

  test "remove_job deletes only its own managed block" do
    existing = [
      "0 0 * * * /usr/local/bin/manual-backup",
      "# >>> conductor:cron-7 Audit",
      "0 3 * * * /usr/bin/server-audit",
      "# <<< conductor:cron-7"
    ].join("\n") + "\n"
    ssh = FakeSsh.new([ { stdout: existing }, { stdout: "" } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    client.remove_job(id: "cron-7")

    written = written_crontab(ssh.commands.last)
    assert_includes written, "0 0 * * * /usr/local/bin/manual-backup"
    refute_includes written, "conductor:cron-7"
    refute_includes written, "/usr/bin/server-audit"
  end

  test "remove_job raises when the managed block is absent" do
    ssh = FakeSsh.new([ { stdout: "0 0 * * * /manual" } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    assert_raises(CrontabClient::Error) { client.remove_job(id: "cron-404") }
  end

  test "list_managed returns only conductor blocks with parsed fields" do
    existing = [
      "0 0 * * * /manual",
      "# >>> conductor:cron-7 Audit",
      "0 3 * * * /usr/bin/server-audit",
      "# <<< conductor:cron-7",
      "# >>> conductor:cron-8 Paused",
      "# 0 5 * * * /bin/thing",
      "# <<< conductor:cron-8"
    ].join("\n") + "\n"
    ssh = FakeSsh.new([ { stdout: existing } ])
    client = CrontabClient.new(build_server, ssh_connection: ssh)

    jobs = client.list_managed
    assert_equal 2, jobs.size

    audit = jobs.find { |j| j[:id] == "cron-7" }
    assert_equal "Audit", audit[:name]
    assert_equal "0 3 * * *", audit[:cron_expression]
    assert_equal "/usr/bin/server-audit", audit[:command]
    assert audit[:enabled]

    paused = jobs.find { |j| j[:id] == "cron-8" }
    refute paused[:enabled]
    assert_equal "/bin/thing", paused[:command]
  end
end
