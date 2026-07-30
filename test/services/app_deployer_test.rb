require "test_helper"

# Regression for the false "Step failed: clone_or_pull_repo" on a first Docker
# deploy (Starrrs app 9, deployments 203/204). Two defects fixed:
#   1. git writes "Cloning into '…'" to STDERR even on exit 0; run must decide by
#      exit status, not stderr.
#   2. the clone branch's trailing `... if commit_sha.present?` returned nil on a
#      first deploy (commit_sha is null), failing the step though the clone worked.
class AppDeployerTest < ActiveSupport::TestCase
  # Resolves each command to an execute_with_status-style result and records calls.
  class FakeSsh
    attr_reader :commands, :output
    def initialize(&resolver)
      @commands = []
      @resolver = resolver
    end

    def execute_with_status(command)
      @commands << command
      r = @resolver.call(command)
      @output = r[:output]
      r
    end
  end

  def result(success:, stdout: "", stderr: "", exit_code: nil)
    out = stdout.presence || stderr.presence
    { success: success, exit_code: exit_code || (success ? 0 : 1), stdout: stdout, stderr: stderr, output: out }
  end

  def deployer_with(ssh, commit_sha: nil)
    user = User.create!(email: "ad#{SecureRandom.hex(3)}@example.com")
    org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: org)
    server = org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1", ssh_key: key)
    app = org.apps.create!(name: "starrrs", slug: "starrrs", server: server, deploy_method: "docker",
                           repository_url: "git@github.com:x/y.git", branch: "main")
    dep = app.deployments.create!(user: user, commit_sha: commit_sha)
    d = AppDeployer.new(app, dep)
    d.instance_variable_set(:@ssh, ssh)
    d
  end

  test "first-deploy clone that writes 'Cloning into' to stderr is NOT a false failure" do
    ssh = FakeSsh.new do |cmd|
      if cmd.include?("test -d")            then result(success: true, stdout: "missing\n")
      elsif cmd.include?("git clone")       then result(success: true, stderr: "Cloning into '/opt/conductor/apps/starrrs'...\n")
      else result(success: true)
      end
    end
    d = deployer_with(ssh, commit_sha: nil) # first deploy: no sha

    assert d.send(:clone_or_pull_repo), "a successful first-deploy clone must return truthy, not nil"
    assert ssh.commands.any? { |c| c.include?("git clone") }, "should have cloned"
  end

  test "a clone that exits non-zero fails the step (exit status, not stderr, decides)" do
    ssh = FakeSsh.new do |cmd|
      if cmd.include?("test -d")      then result(success: true, stdout: "missing\n")
      elsif cmd.include?("git clone") then result(success: false, exit_code: 128, stderr: "fatal: repository not found\n")
      else result(success: true)
      end
    end
    d = deployer_with(ssh, commit_sha: nil)

    refute d.send(:clone_or_pull_repo), "a real clone failure (exit 128) must fail the step"
  end

  test "existing checkout pulls and returns the pull result" do
    ssh = FakeSsh.new do |cmd|
      if cmd.include?("test -d")                    then result(success: true, stdout: "exists\n")
      elsif cmd.include?("git fetch")               then result(success: true, stdout: "HEAD is now at abc123\n")
      else result(success: true)
      end
    end
    d = deployer_with(ssh, commit_sha: nil)

    assert d.send(:clone_or_pull_repo)
    assert ssh.commands.any? { |c| c.include?("git fetch") }, "existing .git should pull, not clone"
    refute ssh.commands.any? { |c| c.include?("git clone") }
  end
end
