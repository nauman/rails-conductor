require "test_helper"

# ADR 0003 — the artifact contract. A docker deploy must leave behind an
# immutable, labelled, retained release, because that is what makes rollback and
# the Kamal ops CLI work at all.
class DockerArtifactContractTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands
    def initialize(output: "") = (@commands = []; @output = output)
    def execute(cmd) = (@commands << cmd; true)
    def execute_with_status(cmd)
      @commands << cmd
      { success: true, output: @output, stderr: "" }
    end
    def output = @output
    def success? = true
    def error = nil
  end

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, image_name: "shop", repository_url: "https://github.com/x/y.git")
    @deployment = @app.deployments.create!(status: "deploying", commit_sha: "abc1234def5678")
    @deployer = AppDeployer.new(@app, @deployment)
  end

  def commands_from(step)
    ssh = FakeSsh.new
    @deployer.stub(:ssh, ssh) { @deployer.send(step) }
    ssh.commands
  end

  test "builds an immutable SHA-tagged image, not only :latest" do
    build = commands_from(:build_image).join(" ")

    assert_includes build, "-t shop:abc1234def56", "must tag by commit SHA"
    assert_includes build, "-t shop:latest", ":latest stays as a convenience pointer"
  end

  test "falls back to a deployment-scoped tag when no SHA is known" do
    @deployment.update!(commit_sha: nil)

    assert_includes commands_from(:build_image).join(" "), "-t shop:d#{@deployment.id}"
  end

  # `kamal app logs/exec/console` locate a container by its service label. No
  # label means docker apps get none of the Kamal ops surface.
  test "labels the container so the Kamal ops CLI can find it" do
    run = commands_from(:start_container).find { |c| c.start_with?("docker run") }

    assert_includes run, "--label service=app-#{@app.id}"
    assert_includes run, "--label role=web"
    assert_includes run, "--label destination=production"
  end

  # ADR 0004: the service label must be the STABLE key, so a rename can't orphan it.
  test "the service label is the stable resource key, not the slug" do
    run = commands_from(:start_container).find { |c| c.start_with?("docker run") }

    assert_includes run, "service=app-#{@app.id}"
    assert_not_includes run, "service=shop"
  end

  test "labels carry the infra revision so residue is identifiable" do
    run = commands_from(:start_container).find { |c| c.start_with?("docker run") }

    assert_includes run, "--label conductor.infra_revision=1"
    assert_includes run, "--label conductor.release=abc1234def56"
  end

  test "runs the immutable tag, never :latest" do
    run = commands_from(:start_container).find { |c| c.start_with?("docker run") }

    assert_includes run, "shop:abc1234def56"
    assert_not_includes run, "shop:latest", "running :latest makes the release ambiguous"
  end

  # The old `docker image prune -f` deleted the very artifact rollback needs.
  test "cleanup retains prior releases instead of pruning them away" do
    cleanup = commands_from(:cleanup).join(" | ")

    assert_includes cleanup, "tail -n +#{AppDeployer::RETAINED_RELEASES + 1}",
                    "keeps the newest N releases"
    assert_includes cleanup, "grep -v '^latest '", "never removes the :latest pointer"
  end
end
