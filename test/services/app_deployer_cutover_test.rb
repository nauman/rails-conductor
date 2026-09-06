require "test_helper"

# ADR 0003 — candidate → health → swap → drain. These tests are about ORDER:
# a cutover is only zero-downtime if nothing stops the old container until
# traffic is already on a proven new one.
class AppDeployerCutoverTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    def initialize(healthy: true, fail_on: nil)
      @commands = []
      @healthy = healthy
      @fail_on = fail_on
    end

    # Sensitive values travel as FILE CONTENT over scp, never as a command — the
    # whole point, since anything passed through exec becomes a command string on
    # the remote host.
    attr_reader :uploads
    def upload_content(content, path, mode: nil)
      (@uploads ||= []) << [ content, path, mode ]
      true
    end

    def execute_with_status(cmd)
      @commands << cmd
      failed = @fail_on && cmd.include?(@fail_on)
      { success: !failed, output: output_for(cmd), stderr: failed ? "forced failure" : "" }
    end

    def output = @last_output.to_s

    def execute(cmd)
      execute_with_status(cmd)
      true
    end

    def output_for(cmd)
      @last_output =
        if cmd.include?("label=service=")     then "oldcid999"
        elsif cmd.include?("docker inspect")  then "172.18.0.5 "
        elsif cmd.include?("{{.Ports}}")      then "MAYBE_FREE"
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
    # NOTE on the fixture: real traffic through AppDeployer is deploy_method
    # "docker" — DeployAppJob sends kamal apps to KamalDeployer. It says "kamal"
    # here because the migration and seed GATES this file also exercises are
    # kamal-only by validation, and the cutover logic under test is
    # method-agnostic. Worth knowing when reading an assertion about dispatch.
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "kamal",
                             port: 3000, image_name: "shop", domain: "shop.example.com",
                             health_check_path: "/up", repository_url: "https://github.com/x/y.git")
    @deployment = @app.deployments.create!(status: "deploying", commit_sha: "abc1234def")
    @deployer = AppDeployer.new(@app, @deployment)
  end

  # Drives the cutover steps in order against a recording fake.
  def cutover(ssh)
    @deployer.stub(:ssh, ssh) do
      @deployer.stub(:sleep, nil) do
        # Drive the REAL step list, not a copy of it. A duplicated list lets the
        # production order and the tested order drift apart silently, which is
        # exactly the kind of gap that makes an ordering test worthless.
        (AppDeployer::ZERO_DOWNTIME_STEPS - %i[ensure_docker prepare_repository_access clone_or_pull_repo build_image cleanup])
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

  # ADR 0006. A candidate is a thing that has not won yet, so it must not be
  # granted the lifecycle of a thing that has. `unless-stopped` means "come back on
  # daemon start unless a human explicitly stopped you", and nobody stops a deploy
  # that was abandoned halfway — one such candidate returned with every reboot and
  # ran production jobs on stale code for fifteen days.
  test "a candidate is born ephemeral so an abandoned one dies at the next reboot" do
    ssh = FakeSsh.new
    cutover(ssh)

    run_cmd = ssh.commands.find { |c| c.start_with?("docker run -d") }
    assert run_cmd, "expected the candidate to be started"
    assert_includes run_cmd, "--restart no"
    assert_not_includes run_cmd, "--restart unless-stopped"
  end

  # NOTHING SERVING IS EVER EPHEMERAL. Promotion runs before the edge moves, so
  # there is no instant where production carries traffic on `--restart no`. Two
  # earlier orderings — after the drain, then after the edge swap — only narrowed
  # that window; this removes it.
  test "the candidate is promoted before the edge swap, so production is never ephemeral" do
    ssh = FakeSsh.new
    cutover(ssh)

    promote = index_of(ssh, /docker update --restart unless-stopped/)
    assert promote, "expected the candidate to be promoted"
    edge = index_of(ssh, /kamal-proxy|caddy|deploy .*--target/i) || index_of(ssh, /docker stop/)
    assert_operator promote, :<, edge,
                    "promotion must precede anything that moves traffic onto the candidate"
  end

  # A survivor of an earlier attempt can already be serving on `--restart no`.
  # Every step between adopting it and promoting it is a chance for the process to
  # die and leave production unable to come back, so repair it on adoption.
  test "a reused serving candidate has its restart policy repaired immediately" do
    # The reuse branch is only taken when the SERVING container and the container
    # under the candidate's name are the same one — i.e. a previous attempt died
    # after publishing the edge. This fake makes both lookups agree.
    same = Class.new(FakeSsh) do
      def output_for(_cmd) = (@last_output = "samecid777")
    end.new

    @deployer.stub(:ssh, same) { @deployer.stub(:sleep, nil) { @deployer.send(:start_candidate) } }

    assert same.commands.any? { |c| c.match?(/docker ps -q -f name=/) }, "expected the reuse probe"
    assert same.commands.any? { |c| c.match?(/docker update --restart unless-stopped samecid777/) },
           "a candidate adopted while already serving must not be left ephemeral: #{same.commands.last(3)}"
    assert same.commands.none? { |c| c.start_with?("docker run -d") },
           "the serving container must be reused, not replaced"
  end

  # The record must never point at a container that is about to be removed.
  test "a failed promotion restores the recorded container to the incumbent" do
    ssh = FakeSsh.new(fail_on: "docker update --restart")
    @app.update_columns(container_id: "newcid111")

    @deployer.stub(:ssh, ssh) do
      @deployer.stub(:sleep, nil) do
        @deployer.instance_variable_set(:@previous_container, "oldcid999")
        @deployer.instance_variable_set(:@candidate_container, "newcid111")
        @deployer.instance_variable_set(:@candidate_name, "app-x")
        @deployer.send(:promote_candidate)
      end
    end

    assert_equal "oldcid999", @app.reload.container_id,
                 "the record must follow the container that is still serving"
  end

  # The outage this nearly caused: in the reuse branch the candidate IS the
  # incumbent, so the container_id guard is skipped — and discarding would then
  # `docker rm -f` the container currently serving the site, to fix a restart policy.
  test "a failed promotion never removes a candidate that is already serving" do
    ssh = FakeSsh.new(fail_on: "docker update --restart")

    ok = @deployer.stub(:ssh, ssh) do
      @deployer.instance_variable_set(:@previous_container, "samecid777")
      @deployer.instance_variable_set(:@candidate_container, "samecid777")
      @deployer.instance_variable_set(:@candidate_name, "app-x")
      @deployer.send(:promote_candidate)
    end

    assert_not ok, "an unpromotable serving container must fail the deploy"
    assert ssh.commands.none? { |c| c.match?(/docker rm -f/) },
           "must NEVER remove the live serving container to fix a restart policy"
  end

  # A failure here costs nothing: the edge has not moved and the incumbent is still
  # serving, so it is an ordinary pre-cutover failure like a failed health check.
  test "a candidate that cannot be promoted is discarded, and traffic never moves" do
    ssh = FakeSsh.new(fail_on: "docker update --restart")

    ok = @deployer.stub(:ssh, ssh) do
      @deployer.stub(:sleep, nil) { @deployer.send(:start_candidate) && @deployer.send(:promote_candidate) }
    end

    assert_not ok, "refusing to move traffic onto a container that would not survive a reboot"
    assert index_of(ssh, /docker rm -f/), "the unpromotable candidate must be discarded"
    assert_nil index_of(ssh, /docker stop/), "the incumbent must keep serving"
  end

  test "a kamal-proxy app with a domain uses the zero-downtime path" do
    assert @deployer.send(:zero_downtime_cutover?)
  end

  test "a caddy app also gets zero-downtime, via a second host port" do
    @app.server.update!(edge_type: "caddy")
    assert @deployer.send(:zero_downtime_cutover?)
    assert_not @deployer.send(:proxy_targets_container?),
               "caddy targets host:port, so the candidate needs its own port"
  end

  test "an unproxied app falls back to stop-first — its host port IS the service" do
    @app.server.update!(edge_type: "none")
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
    assert_includes run, "--name app-#{@app.id}-r1-d#{@deployment.id}-abc1234"
    assert_not_includes run, "-p 3000:3000",
                        "binding the old container's port defeats running alongside"
    assert_includes run, "--network"
  end

  test "same-commit config redeploys get a new container name" do
    first = @app.release_container_name(@deployment.commit_sha, deployment_id: @deployment.id)
    @deployment.update!(status: "succeeded")
    later = @app.deployments.create!(status: "deploying", commit_sha: @deployment.commit_sha)
    second = @app.release_container_name(later.commit_sha, deployment_id: later.id)

    assert_not_equal first, second,
                     "reusing the serving name makes candidate cleanup remove the live release"
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

  test "schema gates run inside the healthy candidate before traffic moves" do
    ssh = FakeSsh.new
    cutover(ssh)

    migrate = index_of(ssh, /docker exec .* db:migrate/)
    pending = index_of(ssh, /docker exec .* db:abort_if_pending_migrations/)
    swap = index_of(ssh, /kamal-proxy deploy/)

    assert migrate, "expected db:migrate in the candidate"
    assert pending, "expected the pending-migration assertion in the candidate"
    assert migrate < pending
    assert pending < swap, "traffic must not move before the schema gate passes"
  end

  test "a failed migration discards the candidate and leaves the old release serving" do
    ssh = FakeSsh.new(fail_on: "db:migrate")
    results = cutover(ssh)

    assert_not results[:run_gated_migrations]
    assert ssh.commands.any? { |c| c.match?(/docker rm -f .*app-#{@app.id}-r1/) }
    assert_not ssh.commands.any? { |c| c.include?("kamal-proxy deploy") }
    assert_not ssh.commands.any? { |c| c.match?(/docker stop oldcid999/) }
  end

  test "requested seeds run in the candidate and are recorded before cutover" do
    @app.update!(seed_on_next_deploy: true)
    ssh = FakeSsh.new
    cutover(ssh)

    seed = index_of(ssh, /docker exec .* db:seed/)
    swap = index_of(ssh, /kamal-proxy deploy/)

    assert seed
    assert seed < swap
    assert @app.seed_applications.last.proven?
    refute @app.reload.seed_on_next_deploy?
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

  # --- Caddy: same guarantees, different mechanism ---

  test "a caddy candidate binds its OWN loopback port, not the live one" do
    @app.server.update!(edge_type: "caddy")
    ssh = FakeSsh.new
    fake_edge = Object.new
    def fake_edge.publish(**) = { route_id: "r1" }
    Edge.stub(:for, ->(*, **) { fake_edge }) { cutover(ssh) }

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_match(/-p 127\.0\.0\.1:\d+:3000/, run, "candidate needs its own host port")
    assert_not_includes run, "-p 3000:3000", "must not contend for the live port"
  end

  test "a caddy candidate separates the published port from the Rails runtime port" do
    @app.server.update!(edge_type: "caddy")
    @app.update!(port: 9080)
    ssh = FakeSsh.new
    cutover(ssh)

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_match(/-p 127\.0\.0\.1:\d+:3000/, run,
                 "the candidate host port must forward to Rails' internal port")
    assert_includes run, "-e PORT=3000"
    assert_not_includes run, ":9080", "9080 is the stable host publish port, not a container port"
  end

  test "a configured PORT overrides the default Rails runtime port" do
    @app.server.update!(edge_type: "caddy")
    @app.update!(port: 9080)
    @app.env_variables.create!(key: "PORT", value: "4000")
    ssh = FakeSsh.new
    cutover(ssh)

    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_match(/-p 127\.0\.0\.1:\d+:4000/, run)
    assert_includes run, "-e PORT=4000"
  end

  test "a candidate receives the derived dedicated DATABASE_URL without logging it" do
    cluster = @org.database_clusters.create!(server: @server, name: @app.dedicated_db_container_name,
                                             container_name: @app.dedicated_db_container_name,
                                             admin_username: "conductor", admin_password: "x", port: 5432)
    cluster.databases.create!(organization: @org, app: @app, name: "shop",
                              username: "shop", password: "top-secret", status: "active")
    ssh = FakeSsh.new
    cutover(ssh)

    # The derived DATABASE_URL carries the database password, and it used to ride on
    # the docker run command line — readable in the host process table for the life
    # of the command. It now travels in a 0600 file uploaded over scp.
    run = ssh.commands.find { |c| c.start_with?("docker run") }
    assert_includes run, "--env-file"
    assert_not_includes run, "top-secret", "a password must not be an argv element"

    content, path, mode = ssh.uploads.to_a.first
    assert_includes content.to_s, "DATABASE_URL=", "the candidate must still receive it"
    assert_includes content.to_s, "top-secret"
    assert_equal 0o600, mode
    assert_includes path.to_s, "conductor-env"

    display = @deployment.reload.log.to_s
    assert_not_includes display, "top-secret"
  end

  test "a caddy candidate is probed on its own port, then Caddy is repointed at it" do
    @app.server.update!(edge_type: "caddy")
    ssh = FakeSsh.new
    @deployer.stub(:ssh, ssh) do
      @deployer.stub(:sleep, nil) do
        @deployer.send(:start_candidate)
        @deployer.send(:health_check_candidate)
      end
    end
    port = @deployer.send(:candidate_host_port)

    health = ssh.commands.find { |c| c.include?("curl -sf") }
    assert_includes health, "127.0.0.1:#{port}", "probe the candidate's own port"
  end

  test "a free port is probed for, not assumed" do
    @app.server.update!(edge_type: "caddy")
    ssh = FakeSsh.new
    @deployer.stub(:ssh, ssh) { @deployer.send(:candidate_host_port) }

    assert ssh.commands.any? { |c| c.include?("{{.Ports}}") },
           "must ask docker whether the port is taken"
    assert_not ssh.commands.any? { |c| c.include?("ss -ltn") },
               "`ss ... || echo FREE` reported a MISSING ss as free — exactly backwards"
  end

  # head -n1 returned ONE id, so a second leftover survived — reintroducing the
  # split-container condition this step exists to prevent.
  test "stop-first removes EVERY container wearing the app's identity" do
    @app.server.update!(edge_type: "none")
    ssh = FakeSsh.new
    @deployer.stub(:ssh, ssh) { @deployer.send(:stop_old_container) }

    cmd = ssh.commands.join(" ")
    assert_includes cmd, "for cid in $(docker ps -aq", "must iterate every match, not take the first"
    assert_includes cmd, "for s in app-#{@app.id}"
  end

  test "the previous container is resolved by service label, not a fixed name" do
    ssh = FakeSsh.new
    cutover(ssh)

    assert ssh.commands.any? { |c| c.include?("label=service=app-#{@app.id}") },
           "a Kamal-era or renamed app is not findable by the fixed name"
  end
end
