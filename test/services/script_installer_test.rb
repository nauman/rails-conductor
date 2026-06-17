require "test_helper"
require "base64"

class ScriptInstallerTest < ActiveSupport::TestCase
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

  def build_server
    server = Server.new(name: "edge-1", status: "online", ip_address: "203.0.113.10", ssh_user: "deploy")
    server.define_singleton_method(:ssh_configured?) { true }
    server
  end

  def body_in(command)
    Base64.decode64(command[/echo (\S+) \|/, 1].to_s)
  end

  test "install writes the body to a conductor-prefixed path and returns it" do
    ssh = FakeSsh.new([ { stdout: "" } ])
    installer = ScriptInstaller.new(build_server, ssh_connection: ssh)

    path = installer.install(name: "server-audit", body: "#!/bin/bash\necho hi\n")

    assert_equal "/usr/local/bin/conductor-server-audit", path
    cmd = ssh.commands.first
    assert_equal "#!/bin/bash\necho hi\n", body_in(cmd)
    assert_includes cmd, "> /usr/local/bin/conductor-server-audit"
    assert_includes cmd, "chmod +x"
  end

  test "install raises on a failed SSH write" do
    ssh = FakeSsh.new([ { success: false, stderr: "permission denied" } ])
    installer = ScriptInstaller.new(build_server, ssh_connection: ssh)

    error = assert_raises(ScriptInstaller::Error) { installer.install(name: "x", body: "y") }
    assert_includes error.message, "permission denied"
  end
end
