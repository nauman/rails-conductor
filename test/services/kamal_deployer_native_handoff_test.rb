require "test_helper"
require "tmpdir"

class KamalDeployerNativeHandoffTest < ActiveSupport::TestCase
  class FakeShell
    attr_reader :runs

    def initialize(fail_on: nil)
      @fail_on = fail_on
      @runs = []
    end

    def run(*command, chdir: nil, env: {})
      @runs << { command: command, chdir: chdir, env: env }
      text = command.last.to_s
      success = @fail_on.nil? || !text.include?(@fail_on)
      yield "output" if block_given?
      LocalShell::Result.new(success:, exit_code: success ? 0 : 1, output: "output")
    end
  end

  class NativePortSsh
    attr_reader :commands

    def initialize(port_busy_after_release: false, fail_disable: false)
      @port_busy_after_release = port_busy_after_release
      @fail_disable = fail_disable
      @commands = []
    end

    def execute_with_status(command)
      @commands << command
      if @fail_disable && command.include?("systemctl --user disable --now")
        return { success: false, exit_code: 1, output: "", stderr: "failed" }
      end

      output = case command
      when /systemctl --user is-active/
        "appone-server.service\nappone-server.socket\n"
      when /docker ps --filter publish=/
        ""
      when /ss -ltnH/
        @port_busy_after_release ? "LISTEN 0 1024 127.0.0.1:9080\n" : ""
      else
        ""
      end
      { success: true, exit_code: 0, output:, stderr: "" }
    end
  end

  setup do
    @workspace = Dir.mktmpdir("kamal-native-handoff")
    @ssh_root = Dir.mktmpdir("kamal-native-handoff-ssh")
    ENV["KAMAL_WORKSPACE"] = @workspace
    ENV["CONDUCTOR_SSH_HOME"] = @ssh_root

    user = User.create!(email: "native-handoff@example.com")
    organization = Organization.create_for(user, name: "Native handoff")
    key = SshKey.create!(name: "native-handoff", private_key: valid_private_key, organization:)
    server = organization.servers.create!(name: "caddy", status: "online", ip_address: "10.0.0.9",
                                           ssh_key: key, ssh_user: "deploy", edge_type: "caddy")
    @app = organization.apps.create!(name: "Appone", slug: "appone", server:, deploy_method: "kamal",
                                     repository_url: "https://github.com/example/appone.git", branch: "main",
                                     domain: "appone.example.com", port: 9080)
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "secret", secret: true)
    @deployment = @app.deployments.create!(user:)
    write_checkout_file("config/deploy.yml", "servers:\n  web:\n    proxy: false\n")
  end

  teardown do
    ENV.delete("KAMAL_WORKSPACE")
    ENV.delete("CONDUCTOR_SSH_HOME")
    FileUtils.remove_entry(@workspace) if Dir.exist?(@workspace)
    FileUtils.remove_entry(@ssh_root) if Dir.exist?(@ssh_root)
  end

  test "a Caddy fixed-port deploy disables matching native units before Kamal boots" do
    shell = FakeShell.new
    ssh = NativePortSsh.new

    deploy(shell:, ssh:)

    assert ssh.commands.any? { |command| command.include?("systemctl --user disable --now") &&
      command.include?("appone-server.service") && command.include?("appone-server.socket") }
    assert_equal "succeeded", @deployment.reload.status
  end

  test "a failed Kamal boot restores the native units and verifies their health" do
    shell = FakeShell.new(fail_on: "kamal deploy")
    ssh = NativePortSsh.new

    deploy(shell:, ssh:)

    assert ssh.commands.any? { |command| command.include?("systemctl --user enable") }
    assert ssh.commands.any? { |command| command.include?("systemctl --user start") }
    assert ssh.commands.any? { |command| command.include?("curl -fsS") && command.include?("/up") }
    refute shell.runs.any? { |run| run[:command].last.to_s.include?("kamal app boot") },
      "the previous owner was native, so recovery must not boot a Kamal image"
    assert_equal "failed", @deployment.reload.status
  end

  test "a port still owned after the app-specific release blocks before Kamal deploy" do
    shell = FakeShell.new
    ssh = NativePortSsh.new(port_busy_after_release: true)

    deploy(shell:, ssh:)

    refute shell.runs.any? { |run| run[:command].last.to_s.include?("kamal deploy") }
    assert_match(/still in use/i, @deployment.reload.failure_reason)
    assert_equal "failed", @deployment.status
  end

  test "a partial native stop failure still restores the captured units" do
    shell = FakeShell.new
    ssh = NativePortSsh.new(fail_disable: true)

    deploy(shell:, ssh:)

    assert ssh.commands.any? { |command| command.include?("systemctl --user enable") }
    assert ssh.commands.any? { |command| command.include?("systemctl --user start") }
    refute shell.runs.any? { |run| run[:command].last.to_s.include?("kamal deploy") }
    assert_equal "failed", @deployment.reload.status
  end

  test "an invalid Rails master key fails before the native owner is stopped" do
    @app.env_variables.create!(key: "RAILS_MASTER_KEY", value: "x" * 128, secret: true)
    shell = FakeShell.new
    ssh = NativePortSsh.new

    deploy(shell:, ssh:)

    refute ssh.commands.any? { |command| command.include?("systemctl --user disable --now") }
    refute shell.runs.any? { |run| run[:command].last.to_s.include?("kamal deploy") }
    assert_match(/32 hexadecimal/i, @deployment.reload.failure_reason)
    assert_equal "failed", @deployment.status
  end

  private

  def deploy(shell:, ssh:)
    deployer = KamalDeployer.new(@app, @deployment, shell:, ssh:, allow_self_deploy: true)
    deployer.stub(:caddy_cutover, nil) { deployer.deploy! }
  end

  def write_checkout_file(relative_path, content)
    path = File.join(@workspace, @app.slug, relative_path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end
end
