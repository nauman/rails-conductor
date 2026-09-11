require "test_helper"
require "tmpdir"

# A monorepo keeps the Rails app in a subdirectory. Git still belongs to the
# repository; Kamal and every config read belong to the app inside it. These
# tests pin that split, because conflating the two is the whole defect class:
# a clone that runs in the subdirectory never produces a repo, and a `kamal`
# that runs at the root never finds config/deploy.yml.
class KamalDeployerMonorepoTest < ActiveSupport::TestCase
  class RecordingShell
    attr_reader :runs
    def initialize = @runs = []

    def run(*command, chdir: nil, env: {})
      @runs << { command: command, chdir: chdir, env: env }
      yield "out" if block_given?
      LocalShell::Result.new(success: true, exit_code: 0, output: "out")
    end
  end

  setup do
    @workspace = Dir.mktmpdir("kamal-monorepo")
    ENV["KAMAL_WORKSPACE"] = @workspace
    @ssh_root = Dir.mktmpdir("kamal-monorepo-ssh")
    ENV["CONDUCTOR_SSH_HOME"] = @ssh_root

    user = User.create!(email: "mono@example.com")
    @org = Organization.create_for(user, name: "Mono")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy")
    @app = @org.apps.create!(name: "Hushnote", slug: "hushnote", server: @server, deploy_method: "kamal",
                             repository_url: "https://github.com/pavelabs/alfaaz.git", branch: "main",
                             domain: "hushnote.app", app_root: "alfaaz-rails")
  end

  teardown do
    ENV.delete("KAMAL_WORKSPACE")
    ENV.delete("CONDUCTOR_SSH_HOME")
    FileUtils.remove_entry(@workspace) if @workspace && Dir.exist?(@workspace)
    FileUtils.remove_entry(@ssh_root) if @ssh_root && Dir.exist?(@ssh_root)
  end

  def checkout_dir = File.join(@workspace, @app.slug)
  def app_dir = File.join(checkout_dir, "alfaaz-rails")

  # Build a checkout that looks like the real monorepo: a git repo at the root,
  # the Rails app one level down.
  def build_monorepo_checkout
    FileUtils.mkdir_p(File.join(app_dir, "config"))
    FileUtils.mkdir_p(File.join(app_dir, ".kamal"))
    FileUtils.mkdir_p(File.join(checkout_dir, "desktop"))
    File.write(File.join(app_dir, "config", "deploy.yml"), <<~YML)
      service: hushnote-web
      env:
        secret:
          - RAILS_MASTER_KEY
    YML
  end

  test "app_root is normalized and traversal is refused" do
    @app.update!(app_root: "/alfaaz-rails/")
    assert_equal "alfaaz-rails", @app.reload.app_root, "surrounding slashes should be stripped"

    @app.app_root = ""
    assert @app.valid?, "blank app_root means the app is the repository root"

    [ "../etc", "alfaaz-rails/../../etc", "..", "./alfaaz-rails" ].each do |bad|
      @app.app_root = bad
      assert_not @app.valid?, "#{bad.inspect} should be refused"
      assert @app.errors[:app_root].any?
    end
  end

  test "git runs at the repository root while kamal runs in the app directory" do
    build_monorepo_checkout
    shell = RecordingShell.new
    deployer = KamalDeployer.new(@app, @app.deployments.create!(user: User.first),
                                 shell: shell, ssh: nil, allow_self_deploy: true)

    # Exercise command construction directly — a full deploy! needs a live box.
    sync = deployer.send(:sync_repo_command).last
    assert_includes sync, checkout_dir, "the clone must target the repository root"
    assert_not_includes sync, app_dir, "the clone must not target the app subdirectory"

    assert_equal app_dir, deployer.send(:app_dir)
    assert_equal checkout_dir, deployer.send(:checkout_dir)
  end

  test "deploy.yml and secrets are read from the app directory, not the repo root" do
    build_monorepo_checkout
    deployer = KamalDeployer.new(@app, @app.deployments.create!(user: User.first),
                                 shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)

    assert_equal [ "RAILS_MASTER_KEY" ], deployer.send(:required_secrets),
                 "required_secrets must parse the app's deploy.yml under app_root"

    # The same file at the repo root must NOT be what it reads.
    FileUtils.mkdir_p(File.join(checkout_dir, "config"))
    File.write(File.join(checkout_dir, "config", "deploy.yml"), "env:\n  secret:\n    - WRONG_ONE\n")
    assert_equal [ "RAILS_MASTER_KEY" ], deployer.send(:required_secrets),
                 "a deploy.yml at the repository root must be ignored"
  end

  test "a root-relative app keeps reading from the checkout root" do
    @app.update!(app_root: nil)
    FileUtils.mkdir_p(File.join(checkout_dir, "config"))
    File.write(File.join(checkout_dir, "config", "deploy.yml"), "env:\n  secret:\n    - PLAIN\n")

    deployer = KamalDeployer.new(@app, @app.deployments.create!(user: User.first),
                                 shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)
    assert_equal checkout_dir, deployer.send(:app_dir), "no app_root means app_dir == checkout_dir"
    assert_equal [ "PLAIN" ], deployer.send(:required_secrets)
  end

  # The validations constrain the STRING; a symlink escapes at resolution time.
  # A repository is not a trusted input here: it can ship whatever tree it likes.
  test "a symlinked app_root that leaves the checkout is refused" do
    other = File.join(@workspace, "another-apps-checkout")
    FileUtils.mkdir_p(File.join(other, ".kamal"))
    File.write(File.join(other, ".kamal", "secrets"), "SOMEONE_ELSES_SECRET=1")
    FileUtils.mkdir_p(checkout_dir)
    File.symlink(other, app_dir)

    deployment = @app.deployments.create!(user: User.first)
    deployer = KamalDeployer.new(@app, deployment, shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)

    assert File.directory?(app_dir), "precondition: the symlink looks like a directory"
    assert_not deployer.send(:verify_app_root), "a symlink out of the checkout must stop the deploy"
    assert_match(/outside the checkout/, deployment.reload.log.to_s)
  end

  test "a symlink that stays inside the checkout is allowed" do
    real = File.join(checkout_dir, "packages", "rails-app")
    FileUtils.mkdir_p(real)
    File.symlink(real, app_dir)

    deployer = KamalDeployer.new(@app, @app.deployments.create!(user: User.first),
                                 shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)
    assert deployer.send(:verify_app_root), "containment is about where it resolves, not whether it is a link"
  end

  test "verify_app_root fails closed and keeps its diagnostic when the checkout is unreadable" do
    deployment = @app.deployments.create!(user: User.first)
    deployer = KamalDeployer.new(@app, deployment, shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)

    # No checkout at all: realpath/Dir.children both raise.
    assert_not Dir.exist?(checkout_dir), "precondition: nothing was cloned"
    assert_not deployer.send(:verify_app_root)
    assert_match(/app_root/, deployment.reload.log.to_s,
                 "the failure must still name app_root, not a generic unexpected error")
  end

  # Binding later use to the resolved path is what makes the containment check
  # hold at chdir time, not just at check time.
  test "after verification app_dir is the resolved path, so a later symlink swap cannot redirect kamal" do
    inside = File.join(checkout_dir, "packages", "rails-app")
    FileUtils.mkdir_p(inside)
    File.symlink(inside, app_dir)

    deployer = KamalDeployer.new(@app, @app.deployments.create!(user: User.first),
                                 shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)
    assert deployer.send(:verify_app_root)
    assert_equal File.realpath(inside), deployer.send(:app_dir),
                 "app_dir must be the resolved directory once verified"

    # Swap the link to point outside, as a racing local writer would.
    outside = File.join(@workspace, "elsewhere")
    FileUtils.mkdir_p(outside)
    File.delete(app_dir)
    File.symlink(outside, app_dir)

    assert_equal File.realpath(inside), deployer.send(:app_dir),
                 "the swap must not move where kamal runs"
    assert_not_equal File.realpath(outside), deployer.send(:app_dir)
  end

  test "a second run on the same deployer re-resolves instead of reusing the first path" do
    first = File.join(checkout_dir, "packages", "rails-app")
    FileUtils.mkdir_p(first)
    File.symlink(first, app_dir)

    deployer = KamalDeployer.new(@app, @app.deployments.create!(user: User.first),
                                 shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)
    assert deployer.send(:verify_app_root)
    assert_equal File.realpath(first), deployer.send(:app_dir)

    # The checkout is re-synced between runs; app_root now names a real directory.
    File.delete(app_dir)
    FileUtils.mkdir_p(app_dir)

    assert deployer.send(:verify_app_root), "the second run must verify afresh"
    assert_equal File.realpath(app_dir), deployer.send(:app_dir),
                 "the second run must not reuse the first run's resolved path"
  end

  test "a wrong app_root is named rather than surfacing as a missing config" do
    FileUtils.mkdir_p(File.join(checkout_dir, "desktop"))
    FileUtils.mkdir_p(File.join(checkout_dir, "dev-docs"))
    deployment = @app.deployments.create!(user: User.first)
    deployer = KamalDeployer.new(@app, deployment, shell: RecordingShell.new, ssh: nil, allow_self_deploy: true)

    assert_not deployer.send(:verify_app_root), "a missing app_root directory must stop the deploy"
    assert_match(/alfaaz-rails/, deployment.reload.log.to_s)
    assert_match(/desktop/, deployment.log.to_s, "the error should list what the repo actually holds")
  end

  # Copilot review caught this: the deploy path learned about app_root but the OPS
  # path did not, so logs/exec/console/rollback would look for config/deploy.yml at
  # the repository root and report "no kamal config checked out" for every monorepo
  # app — a deploy that works and an app you cannot then operate.
  test "kamal ops reads the app's deploy.yml from app_root, not the repo root" do
    build_monorepo_checkout
    ops = KamalOps.new(@app, shell: RecordingShell.new)

    # Compared through realpath: app_dir is deliberately the RESOLVED directory, and
    # on macOS the tmpdir itself is a /var -> /private/var symlink.
    assert_equal File.realpath(File.join(app_dir, "config", "deploy.yml")),
                 File.realpath(ops.send(:deploy_config_path))
    assert File.exist?(ops.send(:deploy_config_path)), "the app's config must be the one ops resolves"
  end

  test "kamal ops keeps using the checkout root when there is no app_root" do
    @app.update!(app_root: nil)
    FileUtils.mkdir_p(File.join(checkout_dir, "config"))
    ops = KamalOps.new(@app, shell: RecordingShell.new)

    assert_equal File.join(checkout_dir, "config", "deploy.yml"), ops.send(:deploy_config_path)
  end

  test "kamal ops refuses to follow an app_root that leaves the checkout" do
    outside = File.join(@workspace, "someone-elses-checkout")
    FileUtils.mkdir_p(File.join(outside, "config"))
    File.write(File.join(outside, "config", "deploy.yml"), "service: not-ours\n")
    FileUtils.mkdir_p(checkout_dir)
    File.symlink(outside, app_dir)

    ops = KamalOps.new(@app, shell: RecordingShell.new)
    resolved = ops.send(:deploy_config_path)

    assert_not_equal File.join(File.realpath(outside), "config", "deploy.yml"), resolved,
                     "ops must not resolve into another checkout via a symlink"
  end

  # The containment rule is shared by the deploy and ops paths; pin it directly so
  # a change in one caller cannot quietly weaken it for the other.
  test "contained_app_dir accepts inside, refuses outside, and never raises" do
    helper = Object.new.extend(RepoCheckout)
    FileUtils.mkdir_p(File.join(checkout_dir, "inside"))

    assert_equal File.realpath(File.join(checkout_dir, "inside")),
                 helper.contained_app_dir(checkout_dir, "inside")
    assert_equal checkout_dir, helper.contained_app_dir(checkout_dir, nil), "blank means the repo root"
    assert_nil helper.contained_app_dir(checkout_dir, "does-not-exist")
    assert_nil helper.contained_app_dir(File.join(@workspace, "no-such-checkout"), "inside")

    outside = File.join(@workspace, "outside")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, File.join(checkout_dir, "escape"))
    assert_nil helper.contained_app_dir(checkout_dir, "escape")

    # A sibling whose name merely PREFIXES the checkout path must not pass.
    sibling = "#{checkout_dir}-evil"
    FileUtils.mkdir_p(sibling)
    File.symlink(sibling, File.join(checkout_dir, "prefixy"))
    assert_nil helper.contained_app_dir(checkout_dir, "prefixy")
  end

  # The fallback this replaces was a write primitive, not just a read bug:
  # materialize_ops_config CREATED the config it was then guarded by.
  test "kamal ops refuses an escaping app_root instead of materializing through it" do
    outside = File.join(@workspace, "outside-the-checkout")
    FileUtils.mkdir_p(outside)
    FileUtils.mkdir_p(checkout_dir)
    File.symlink(outside, app_dir)
    @app.update!(self_describing: true)

    ops = KamalOps.new(@app, shell: RecordingShell.new)

    assert_not ops.available?, "an app_root that leaves the checkout must make ops unavailable"
    assert_match(/does not resolve/, ops.unavailable_reason)
    assert_match(/alfaaz-rails/, ops.unavailable_reason)

    # Nothing may have been written through the link.
    assert_not File.exist?(File.join(outside, "config", "deploy.yml")),
               "materialize must not write outside the checkout"
    assert_empty Dir.children(outside), "no generated config may land outside the checkout"
  end

  test "kamal ops materializes into the app directory for a contained app_root" do
    FileUtils.mkdir_p(app_dir)
    @app.update!(self_describing: true)

    ops = KamalOps.new(@app, shell: RecordingShell.new)
    ops.send(:materialize_ops_config)

    assert_nil ops.instance_variable_get(:@materialize_error)
    assert File.exist?(File.join(app_dir, "config", "deploy.yml")),
           "the base config belongs under app_root"
    assert_not File.exist?(File.join(checkout_dir, "config", "deploy.yml")),
               "nothing may be written at the repository root"
  end

  # The precise attack: a config ALREADY present outside the checkout. With a
  # fallback to the composed path, File.exist? is satisfied, available? returns
  # true, and `run` chdirs Kamal into someone else's tree. Nothing in the
  # materialize guard catches this, because materialize never runs.
  test "kamal ops refuses an escaping app_root even when a config already exists outside" do
    outside = File.join(@workspace, "someone-elses-checkout")
    FileUtils.mkdir_p(File.join(outside, "config"))
    File.write(File.join(outside, "config", "deploy.yml"), "service: not-ours\n")
    FileUtils.mkdir_p(checkout_dir)
    File.symlink(outside, app_dir)

    ops = KamalOps.new(@app, shell: RecordingShell.new)

    assert_not ops.available?,
               "an existing config outside the checkout must not make ops available"
    assert_match(/does not resolve/, ops.unavailable_reason)
  end
end
