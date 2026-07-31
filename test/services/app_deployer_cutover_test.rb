require "test_helper"

# ADR 0003 — candidate → health → swap → drain. These tests are about ORDER:
# a cutover is only zero-downtime if nothing stops the old container until
# traffic is already on a proven new one.
class AppDeployerCutoverTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    def initialize(healthy: true)
      @commands = []
      @healthy = healthy
    end

    def execute_with_status(cmd)
      @commands << cmd
      { success: true, output: output_for(cmd), stderr: "" }
    end

    def output = @last_output.to_s

    def execute(cmd)
      execute_with_status(cmd)
      true
    end

    private

    def output_for(cmd)
      @last_output =
        if cmd.include?("label=service=")     then "oldcid999"
        elsif cmd.include?("docker inspect")  then "172.18.0.5 "
        elsif cmd.include?("curl -sf")        then (@healthy ? "healthy" : "")
        elsif cmd.include?("docker ps -q -f name=app-") then "newcid111"
        elsif cmd.include?("docker ps -q")    then "oldcid999"
        else ""
        end
    end
  end

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   edge_type: "kamal_proxy")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, image_name: "shop", domain: "shop.example.com",
                             health_check_path: "/up", repository_url: "https://github.com/x/y.git")
    @deployment = @app.deployments.create!(status: "deploying", commit_sha: "abc1234def")
    @deployer = AppDeployer.new(@app, @deployment)
  end

  # Drives the cutover steps in order against a recording fake.
  def cutover(ssh)
    @deployer.stub(:ssh, ssh) do
      @deployer.stub(:sleep, nil) do
        # Mirror the real pipeline: it aborts on the first failing step, so a
        # failed health check must never reach the swap or the drain.
        %i[start_candidate health_check_candidate republish_edge_route drain_previous_container]
          .each_with_object({}) do |step, out|
            out[step] = @deployer.send(step)
            break out unless out[step]
          end
      end
    end
  end

  def index_of(ssh, pattern)
    ssh.commands.index { |c| c.match?(pattern) }
  end

  test "a kamal-proxy app with a domain uses the zero-downtime path" do
    assert @deployer.send(:zero_downtime_cutover?)
  end

  test "an unproxied or caddy app falls back to stop-first" do
    @app.server.update!(edge_type: "caddy")
    assert_not @deployer.send(:zero_downtime_cutover?)

    @app.server.update!(edge_type: "kamal_proxy")
    @app.update!(domain: nil)
    assert_not @deployer.send(:zero_downtime_cutover?),
               "with no domain there is no route to swap"
  end

  test "the candidate starts with NO host port binding, so it can run alongside" do
    ssh = FakeSsh.new
    cutover(ssh)

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_includes run, "--name app-#{@app.id}-r1-abc1234"
    assert_not_includes run, "-p 3000:3000",
                        "binding the old container's port defeats running alongside"
    assert_includes run, "--network"
  end

  test "nothing stops the old container before the edge has been swapped" do
    ssh = FakeSsh.new
    cutover(ssh)

    swap = index_of(ssh, /kamal-proxy deploy/)
    stop = index_of(ssh, /docker stop/)

    assert swap, "expected an edge swap"
    assert stop, "expected the old container to be drained"
    assert stop > swap, "the old container must only stop AFTER traffic moved"
  end

  test "the candidate is health-checked before any proxy mutation" do
    ssh = FakeSsh.new
    cutover(ssh)

    health = index_of(ssh, /curl -sf/)
    swap = index_of(ssh, /kamal-proxy deploy/)

    assert health, "expected a health check"
    assert health < swap, "must not move traffic to an unproven container"
  end

  test "the edge is swapped to the candidate, not the old container" do
    ssh = FakeSsh.new
    cutover(ssh)

    publish = ssh.commands.find { |c| c.include?("kamal-proxy deploy") }
    assert_includes publish, "newcid111:3000"
    assert_not_includes publish, "oldcid999"
  end

  # The failure that matters: a bad release must be a failed deploy, not an outage.
  test "an unhealthy candidate is discarded and the old container keeps serving" do
    ssh = FakeSsh.new(healthy: false)
    results = cutover(ssh)

    assert_not results[:health_check_candidate], "health check should fail"
    assert ssh.commands.any? { |c| c.match?(/docker rm -f .*app-#{@app.id}-r1/) },
           "the candidate must be removed"
    assert_not ssh.commands.any? { |c| c.include?("kamal-proxy deploy") },
               "traffic must never move to an unhealthy candidate"
    assert_not ssh.commands.any? { |c| c.match?(/docker stop oldcid999/) },
               "the previous release must be left serving"
  end

  test "the previous container is resolved by service label, not a fixed name" do
    ssh = FakeSsh.new
    cutover(ssh)

    assert ssh.commands.any? { |c| c.include?("label=service=app-#{@app.id}") },
           "a Kamal-era or renamed app is not findable by the fixed name"
  end
end
