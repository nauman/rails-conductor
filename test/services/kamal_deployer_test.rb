require "test_helper"
require "tmpdir"

class KamalDeployerTest < ActiveSupport::TestCase
  # Records local commands and returns a canned result.
  class FakeShell
    attr_reader :runs
    def initialize(success: true)
      @success = success
      @runs = []
    end

    def run(*command, chdir: nil, env: {})
      @runs << { command: command, chdir: chdir, env: env }
      yield "…output…" if block_given?
      LocalShell::Result.new(success: @success, exit_code: @success ? 0 : 1, output: "out")
    end
  end

  setup do
    @workspace = Dir.mktmpdir("kamal-test")
    ENV["KAMAL_WORKSPACE"] = @workspace
    # Redirect the deployer's ~/.ssh writes into a tmp dir so tests never touch
    # the real ~/.ssh. (ssh resolves ~ from passwd; the deployer writes there.)
    @ssh_root = Dir.mktmpdir("kamal-sshhome")
    ENV["CONDUCTOR_SSH_HOME"] = @ssh_root
    user = User.create!(email: "kd@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9", ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Kuickr", slug: "kuickr", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/kuickr.git", branch: "main", domain: "kuickr.co")
    @app.env_variables.create!(key: "SECRET_KEY_BASE", value: "skb_xyz")
    @deployment = @app.deployments.create!(user: user)
  end

  teardown do
    ENV.delete("KAMAL_WORKSPACE")
    ENV.delete("CONDUCTOR_SSH_HOME")
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
    FileUtils.remove_entry(@ssh_root) if @ssh_root && Dir.exist?(@ssh_root)
  end

  def deploy_with(shell)
    KamalDeployer.new(@app, @deployment, shell: shell).tap(&:deploy!)
  end

  def with_env(vars)
    old = vars.to_h { |k, _| [ k, ENV[k] ] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def write_checkout_file(relpath, content)
    path = File.join(@workspace, @app.slug, relpath)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
    path
  end

  test "runs git sync then kamal deploy locally, marks deployment succeeded" do
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    cmds = shell.runs.map { |r| r[:command].last }
    assert cmds.any? { |c| c.include?("git clone") && c.include?("kuickr.git") }, "expected a git clone step"
    kamal_run = shell.runs.find { |r| r[:command].last.include?("kamal deploy") }
    assert kamal_run, "expected a kamal deploy step"
    assert_equal File.join(@workspace, "kuickr"), kamal_run[:chdir]
    assert_equal "succeeded", @deployment.reload.status
  end

  test "generates .kamal/secrets from the app's env vars (Conductor = source of truth)" do
    deploy_with(FakeShell.new(success: true))

    secrets = File.read(File.join(@workspace, "kuickr", ".kamal", "secrets"))
    assert_includes secrets, "SECRET_KEY_BASE=skb_xyz"
  end

  test "records the checked-out commit sha on the deployment (for self-deploy reconciliation)" do
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    assert shell.runs.any? { |r| r[:command].first(2) == ["git", "-C"] && r[:command].last == "HEAD" },
           "expected a git rev-parse HEAD step"
    assert @deployment.reload.commit_sha.present?, "expected commit_sha recorded from git rev-parse HEAD"
  end

  test "fails fast with a clear message when a deploy.yml secret is missing from env vars" do
    checkout = File.join(@workspace, @app.slug)
    FileUtils.mkdir_p(File.join(checkout, "config"))
    File.write(File.join(checkout, "config", "deploy.yml"), <<~YML)
      registry:
        password:
          - KAMAL_REGISTRY_PASSWORD
      env:
        secret:
          - RAILS_MASTER_KEY
          - SECRET_KEY_BASE
    YML

    shell = FakeShell.new(success: true)
    deploy_with(shell) # @app only has SECRET_KEY_BASE

    assert_equal "failed", @deployment.reload.status
    assert_match(/KAMAL_REGISTRY_PASSWORD/, @deployment.log.to_s)
    assert_match(/RAILS_MASTER_KEY/, @deployment.log.to_s)
    assert_match(/Environment Variables/i, @deployment.log.to_s)
    refute shell.runs.any? { |r| r[:command].last.to_s.include?("kamal deploy") },
           "must not run kamal when required secrets are missing"
  end

  test "proceeds when all deploy.yml secrets are present" do
    checkout = File.join(@workspace, @app.slug)
    FileUtils.mkdir_p(File.join(checkout, "config"))
    File.write(File.join(checkout, "config", "deploy.yml"), "env:\n  secret:\n    - SECRET_KEY_BASE\n")

    shell = FakeShell.new(success: true)
    deploy_with(shell) # @app has SECRET_KEY_BASE

    assert_equal "succeeded", @deployment.reload.status
  end

  test "self-deploy materializes config/master.key from Conductor's RAILS_MASTER_KEY" do
    @app.update!(self_managed: true)
    FileUtils.mkdir_p(File.join(@workspace, @app.slug))

    with_env("RAILS_MASTER_KEY" => "abc123masterkey") do
      deploy_with(FakeShell.new(success: true))
    end

    assert_equal "abc123masterkey", File.read(File.join(@workspace, @app.slug, "config", "master.key"))
  end

  test "self-deploy preserves the committed .kamal/secrets (resolves from Conductor's env)" do
    @app.update!(self_managed: true)
    committed = "RAILS_MASTER_KEY=$(cat config/master.key)\nKAMAL_REGISTRY_PASSWORD=$KAMAL_REGISTRY_PASSWORD\n"
    write_checkout_file(".kamal/secrets", committed)

    deploy_with(FakeShell.new(success: true))

    assert_equal committed, File.read(File.join(@workspace, @app.slug, ".kamal", "secrets")),
                 "committed secrets must be preserved for a self-deploy (not overwritten)"
  end

  test "self-deploy only requires KAMAL_REGISTRY_PASSWORD; others resolve from Conductor's env" do
    @app.update!(self_managed: true)
    write_checkout_file("config/deploy.yml", <<~YML)
      registry:
        password:
          - KAMAL_REGISTRY_PASSWORD
      env:
        secret:
          - RAILS_MASTER_KEY
          - DATABASE_PASSWORD
    YML

    with_env("RAILS_MASTER_KEY" => "k", "DATABASE_PASSWORD" => "d") do
      deploy_with(FakeShell.new(success: true)) # app has no KAMAL_REGISTRY_PASSWORD
    end

    assert_equal "failed", @deployment.reload.status
    assert_match(/KAMAL_REGISTRY_PASSWORD/, @deployment.log.to_s)
    refute_match(/RAILS_MASTER_KEY/, @deployment.log.to_s)
    refute_match(/DATABASE_PASSWORD/, @deployment.log.to_s)
  end

  test "self-deploy proceeds with only KAMAL_REGISTRY_PASSWORD set + the rest in env" do
    @app.update!(self_managed: true)
    @app.env_variables.create!(key: "KAMAL_REGISTRY_PASSWORD", value: "rpw")
    write_checkout_file("config/deploy.yml", "registry:\n  password:\n    - KAMAL_REGISTRY_PASSWORD\nenv:\n  secret:\n    - RAILS_MASTER_KEY\n")

    with_env("RAILS_MASTER_KEY" => "k") do
      deploy_with(FakeShell.new(success: true))
    end

    assert_equal "succeeded", @deployment.reload.status
  end

  test "self-deploy resolves a deploy.yml secret aliased in .kamal/secrets (POSTGRES_PASSWORD=$DATABASE_PASSWORD)" do
    @app.update!(self_managed: true)
    @app.env_variables.create!(key: "KAMAL_REGISTRY_PASSWORD", value: "rpw")
    write_checkout_file("config/deploy.yml", <<~YML)
      registry:
        password:
          - KAMAL_REGISTRY_PASSWORD
      env:
        secret:
          - DATABASE_PASSWORD
      accessories:
        db:
          env:
            secret:
              - POSTGRES_PASSWORD
    YML
    # The committed secrets file aliases the accessory seed to DATABASE_PASSWORD,
    # which IS in Conductor's container env — so pre-flight must not block on it.
    write_checkout_file(".kamal/secrets", "DATABASE_PASSWORD=$DATABASE_PASSWORD\nPOSTGRES_PASSWORD=$DATABASE_PASSWORD\n")

    with_env("DATABASE_PASSWORD" => "d", "RAILS_MASTER_KEY" => "k") do
      deploy_with(FakeShell.new(success: true))
    end

    assert_equal "succeeded", @deployment.reload.status
    refute_match(/POSTGRES_PASSWORD/, @deployment.log.to_s)
  end

  # Shell where the FIRST `kamal deploy` fails with a stale-lock error, `kamal lock
  # release` succeeds, and the SECOND `kamal deploy` succeeds. All other commands ok.
  class LockedThenOkShell
    attr_reader :commands
    def initialize
      @commands = []
      @deploys = 0
    end

    def run(*command, chdir: nil, env: {})
      script = command.last.to_s
      @commands << script
      yield "…output…" if block_given?
      if script.end_with?("kamal deploy")
        @deploys += 1
        if @deploys == 1
          yield "ERROR (Kamal::Cli::LockError): Deploy lock found" if block_given?
          return LocalShell::Result.new(success: false, exit_code: 1, output: "Deploy lock found")
        end
      end
      LocalShell::Result.new(success: true, exit_code: 0, output: "out")
    end
  end

  test "self-deploy auto-releases a stale kamal lock and retries" do
    @app.update!(self_managed: true)
    @app.env_variables.create!(key: "KAMAL_REGISTRY_PASSWORD", value: "rpw")
    shell = LockedThenOkShell.new

    with_env("RAILS_MASTER_KEY" => "k") do
      KamalDeployer.new(@app, @deployment, shell: shell).deploy!
    end

    assert_equal "succeeded", @deployment.reload.status, "should recover after releasing the lock"
    assert shell.commands.any? { |c| c.end_with?("lock release") }, "expected a kamal lock release"
    assert_equal 2, shell.commands.count { |c| c.end_with?("kamal deploy") }, "expected deploy retried once"
    assert_match(/Stale kamal deploy lock/i, @deployment.log.to_s)
  end

  test "a non-self-managed deploy does NOT auto-release a lock (no stomping concurrent deploys)" do
    shell = LockedThenOkShell.new # @app is not self_managed
    deploy_with(shell)

    assert_equal "failed", @deployment.reload.status
    refute shell.commands.any? { |c| c.end_with?("lock release") }, "must not release locks for non-self apps"
  end

  test "a self-managed deploy logs the replace-and-reconcile note" do
    @app.update!(self_managed: true)
    deploy_with(FakeShell.new(success: true))

    assert_match(/Self-managed deploy/i, @deployment.reload.log.to_s)
    assert_match(/reconciled when the new release boots/i, @deployment.log.to_s)
  end

  test "passes Conductor's env (incl. deploy host) to the kamal subprocess" do
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    env = shell.runs.find { |r| r[:command].last.include?("kamal deploy") }[:env]
    assert_equal "skb_xyz", env["SECRET_KEY_BASE"]
    assert_equal "10.0.0.9", env["DEPLOY_SERVER_IP"]
    assert_equal "deploy", env["DEPLOY_SSH_USER"]
    assert env["SSH_KEYS"].present?, "expected the materialized ssh key path"
  end

  test "builds over SSH (DOCKER_HOST), no docker.sock, and does not override HOME" do
    shell = FakeShell.new(success: true)
    KamalDeployer.new(@app, @deployment, shell: shell).deploy!

    env = shell.runs.find { |r| r[:command].last.include?("kamal deploy") }[:env]
    assert_equal "ssh://deploy@10.0.0.9", env["DOCKER_HOST"]
    # ssh ignores $HOME (resolves ~ from passwd), so we must NOT fake HOME — the
    # ssh config/known_hosts go into the real ~/.ssh instead.
    assert_nil env["HOME"], "must not override HOME; ssh would ignore it anyway"
  end

  test "writes an ssh config Host stanza + identity into the real ~/.ssh (what ssh reads)" do
    shell = FakeShell.new(success: true)
    KamalDeployer.new(@app, @deployment, shell: shell).deploy!

    config = File.read(File.join(@ssh_root, ".ssh", "config"))
    assert_includes config, "Host #{@server.ip_address}"
    assert_includes config, "StrictHostKeyChecking accept-new"
    assert_includes config, "UserKnownHostsFile #{File.join(@ssh_root, ".ssh", "known_hosts")}"
    assert_includes config, "conductor_kuickr", "expected the per-app IdentityFile"
  end

  test "config Host stanza is idempotent across repeat deploys (no duplicate blocks)" do
    KamalDeployer.new(@app, @deployment, shell: FakeShell.new(success: true)).deploy!
    second = @app.deployments.create!(user: @app.organization.users.first)
    KamalDeployer.new(@app, second, shell: FakeShell.new(success: true)).deploy!

    config = File.read(File.join(@ssh_root, ".ssh", "config"))
    assert_equal 1, config.scan("Host #{@server.ip_address}").size, "should upsert, not append duplicates"
  end

  test "pre-seeds the target host key into the real ~/.ssh/known_hosts (skip if already trusted)" do
    shell = FakeShell.new(success: true)
    KamalDeployer.new(@app, @deployment, shell: shell).deploy!

    seed = shell.runs.find { |r| r[:command].last.to_s.include?("ssh-keyscan") }
    assert seed, "expected an ssh-keyscan step to pre-trust the target host"
    assert_includes seed[:command].last, @server.ip_address
    assert_includes seed[:command].last, File.join(@ssh_root, ".ssh", "known_hosts")
    assert_includes seed[:command].last, "ssh-keygen -F", "should skip re-seeding if already trusted"
  end

  test "materializes and then cleans up the target ssh key" do
    captured = nil
    shell = FakeShell.new(success: true)
    # capture the key path the deployer used
    deployer = KamalDeployer.new(@app, @deployment, shell: shell)
    deployer.deploy!
    key_path = shell.runs.last[:env]["SSH_KEYS"]
    refute File.exist?(key_path), "ssh key file should be cleaned up after deploy"
  end

  test "clones via the deploy key (ssh url + GIT_SSH_COMMAND) for a private repo" do
    DeployKey.create!(app: @app, public_key: "ssh-ed25519 AAAA k", private_key: valid_private_key)
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    sync = shell.runs.find { |r| r[:command].last.include?("git clone") }
    assert_includes sync[:command].last, "git@github.com:pavelabs/kuickr.git"
    assert_includes sync[:env]["GIT_SSH_COMMAND"].to_s, "ssh -i "
    assert_includes sync[:env]["GIT_SSH_COMMAND"].to_s, "IdentitiesOnly=yes"
  end

  test "clones via a GitHub App installation token (https + GIT_ASKPASS) when configured" do
    fake_app = Object.new
    def fake_app.clone_token_for(repo) = "ghs_installtoken"
    shell = FakeShell.new(success: true)

    GithubApp.stub(:from_config, fake_app) do
      KamalDeployer.new(@app, @deployment, shell: shell).deploy!
    end

    sync = shell.runs.find { |r| r[:command].last.include?("git clone") }
    assert_includes sync[:command].last, "https://x-access-token@github.com/pavelabs/kuickr.git"
    assert sync[:env]["GIT_ASKPASS"].present?
    refute_includes sync[:command].last, "ghs_installtoken" # token never in the command
  end

  test "uses the https url and no GIT_SSH_COMMAND when there is no deploy key" do
    shell = FakeShell.new(success: true)
    deploy_with(shell)

    sync = shell.runs.find { |r| r[:command].last.include?("git clone") }
    assert_includes sync[:command].last, "https://github.com/pavelabs/kuickr.git"
    assert_nil sync[:env]["GIT_SSH_COMMAND"]
  end

  test "marks the deployment failed when kamal deploy exits nonzero" do
    deploy_with(FakeShell.new(success: false))
    assert_equal "failed", @deployment.reload.status
  end

  test "fails fast when the app has no target host" do
    @server.update!(ip_address: nil)
    deployer = KamalDeployer.new(@app, @deployment, shell: FakeShell.new)
    deployer.deploy!
    assert_equal "failed", @deployment.reload.status
    assert_match "target host", deployer.error
  end
end
