require "test_helper"
require "kamal"

# ADR 0003 keeps Kamal as an ops CLI over artifacts Conductor produces: our
# containers carry Kamal's labels so `kamal app logs / exec / console` and
# `kamal rollback` work against a Conductor-performed deploy.
#
# Those labels are NOT a documented public API. This test asserts the contract
# against the INSTALLED gem, so an upgrade that renames or drops a label fails
# here — loudly, at CI — instead of silently making the ops CLI blind to every
# app Conductor deployed.
class KamalLabelContractTest < ActiveSupport::TestCase
  # What Kamal itself puts on a container (Kamal::Configuration::Role#default_labels).
  REQUIRED_LABELS = %w[service role destination].freeze

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, image_name: "shop", repository_url: "https://github.com/x/y.git")
    @deployment = @app.deployments.create!(status: "deploying", commit_sha: "abc1234def")
  end

  test "Kamal still labels containers with service/role/destination" do
    source = Kamal::Configuration::Role.instance_method(:default_labels).source_location.first
    body = File.read(source)[/def default_labels.*?end/m]

    REQUIRED_LABELS.each do |label|
      assert_includes body, %("#{label}"),
        "Kamal #{Kamal::VERSION} no longer sets the #{label.inspect} label. Our deploy path " \
        "sets it so the Kamal ops CLI can find Conductor-deployed containers (ADR 0003) — " \
        "check what it uses now and update AppDeployer + DockerRollback together."
    end
  end

  test "our docker deploy sets every label Kamal expects" do
    ssh = Class.new do
      attr_reader :commands
      def initialize = @commands = []
      def execute_with_status(cmd) = (@commands << cmd; { success: true, output: "cid", stderr: "" })
      def output = "cid"
    end.new

    deployer = AppDeployer.new(@app, @deployment)
    deployer.stub(:ssh, ssh) { deployer.send(:start_container) }
    run = ssh.commands.find { |c| c.start_with?("docker run") }

    REQUIRED_LABELS.each do |label|
      assert_includes run, "--label #{label}=", "the deploy path must set #{label}"
    end
  end

  test "our docker ROLLBACK sets them too — a rolled-back container must stay findable" do
    ssh = Class.new do
      attr_reader :commands
      def initialize = @commands = []
      def execute_with_status(cmd)
        @commands << cmd
        { success: true, output: (cmd.include?("image inspect") ? "PRESENT" : "cid"), stderr: "" }
      end
    end.new

    DockerRollback.new(@app, @deployment, ssh: ssh).rollback!("abc1234")
    run = ssh.commands.find { |c| c.start_with?("docker run") }

    REQUIRED_LABELS.each { |label| assert_includes run, "--label #{label}=" }
  end

  # The gem is pinned precisely because this contract is undocumented.
  test "kamal is pinned in the Gemfile, not floating" do
    gemfile = File.read(Rails.root.join("Gemfile"))

    assert_match(/gem ["']kamal["'],\s*["']~>/, gemfile,
                 "kamal must stay pinned — an unplanned major bump can break the label contract")
  end
end
