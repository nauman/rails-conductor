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

    # The repository deploy key travels as file CONTENT over scp now, never
    # base64'd into a command — base64 is reversible, so that put a private key in
    # the remote process's argv.
    attr_reader :uploads
    def upload_content(content, path, mode: nil)
      (@uploads ||= []) << [ content, path, mode ]
      true
    end

    def error = nil

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
      elsif cmd.include?("git clone")       then result(success: true, stderr: "Cloning into '/home/deploy/apps/starrrs'...\n")
      else result(success: true)
      end
    end
    d = deployer_with(ssh, commit_sha: nil) # first deploy: no sha

    assert d.send(:clone_or_pull_repo), "a successful first-deploy clone must return truthy, not nil"
    assert ssh.commands.any? { |c| c.include?("git clone") }, "should have cloned"
  end

  test "checkout uses the app's deploy-user-owned directory" do
    d = deployer_with(FakeSsh.new { result(success: true) })

    assert_equal "/home/deploy/apps/starrrs", d.send(:app_dir)
    assert_equal d.app.app_dir, d.send(:app_dir)
  end

  test "private repository clone uses the app deploy key without logging it" do
    ssh = FakeSsh.new do |cmd|
      if cmd.include?("test -d")      then result(success: true, stdout: "missing\n")
      elsif cmd.include?("git clone") then result(success: true, stderr: "Cloning into 'starrrs'...\n")
      else result(success: true)
      end
    end
    d = deployer_with(ssh)
    private_key = valid_private_key
    d.app.create_deploy_key!(public_key: "ssh-ed25519 AAAA conductor-starrrs", private_key: private_key)

    assert d.send(:prepare_repository_access)
    assert d.send(:clone_or_pull_repo)

    clone = ssh.commands.find { |cmd| cmd.include?("git clone") }
    assert_includes clone, "GIT_SSH_COMMAND="
    assert_includes clone, "git@github.com:x/y.git"
    refute_includes clone, "https://github.com"
    refute_includes d.deployment.log, private_key
    # Not merely absent from the LOG: absent from every command. Redacting the
    # logged copy hid the key from us, not from the host's process table.
    assert_empty ssh.commands.grep(/PRIVATE KEY/)
    assert ssh.uploads.to_a.any? { |content, _p, mode| content == private_key && mode == 0o600 }
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

  # A docker app whose DB is a container name (conductor-postgres) must join the
  # shared network, or it crash-loops on host-name resolution.
  test "start_container joins the app's docker network" do
    ssh = FakeSsh.new do |cmd|
      cmd.include?("docker ps -q -f name=") ? result(success: true, stdout: "cid123\n") : result(success: true)
    end
    d = deployer_with(ssh) # docker app → deploy_network "kamal"

    assert d.send(:start_container)
    runcmd = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_includes runcmd, "--network kamal"
  end

  test "docker deploy records the shipped sha (no more commit_sha: null)" do
    sha = "8566f11c1bff253f268d2c6190d9773f6eb3b568"
    ssh = FakeSsh.new do |cmd|
      if cmd.include?("test -d")             then result(success: true, stdout: "missing\n")
      elsif cmd.include?("git clone")        then result(success: true, stderr: "Cloning into '…'\n")
      elsif cmd.include?("git rev-parse")    then result(success: true, stdout: "#{sha}\n")
      else result(success: true)
      end
    end
    d = deployer_with(ssh, commit_sha: nil)

    assert d.send(:clone_or_pull_repo)
    assert_equal sha, d.deployment.reload.commit_sha
  end

  test "deploy_network: docker + kamal get the shared network, native gets none" do
    org = Organization.create_for(User.create!(email: "dn@example.com"), name: "Acme")
    mk = ->(m) { org.apps.create!(name: "a-#{m}", slug: "a-#{m}", deploy_method: m, repository_url: "https://x/y.git") }

    assert_equal "kamal", mk.("docker").deploy_network
    assert_equal "kamal", mk.("kamal").deploy_network
    assert_nil mk.("native").deploy_network
  end
  # Asserts the GUARANTEE, not the structure: the repository key is cleaned up even
  # when the env cleanup raises and reporting that failure raises too. (`log`
  # persists and broadcasts, and both can fail exactly when a deploy is already going
  # wrong.) Mutation-checked — it does not depend on which of the two guards happens
  # to be doing the work, which is the point of testing behaviour.
  test "a raising cleanup, and a raising report of it, do not skip the other cleanup" do
    ssh = FakeSsh.new { |_| result(success: false, exit_code: 1, stderr: "stop here") }
    d = deployer_with(ssh)
    repository_cleaned = false

    d.define_singleton_method(:remove_env_file!) { raise "env cleanup exploded" }
    d.define_singleton_method(:log) { |_| raise "and logging exploded" }
    d.define_singleton_method(:cleanup_repository_access) { repository_cleaned = true }

    assert_nothing_raised { d.deploy! }

    assert repository_cleaned,
           "the repository key must be cleaned even when the env cleanup and its report both raise"
  end

end
