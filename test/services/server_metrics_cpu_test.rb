require "test_helper"

# `fleet_status` published `cpu: server.cpu_percent` — CPU UTILISATION — under a
# key that reads as a core count. Capacity decisions were made on it.
#
# During the InventList migration that nearly sent the flagship to the wrong box:
# a 6-core host reported `cpu: 1` (1% busy) and a 2-core host reported `cpu: 4`.
# The numbers were correct; the NAME was wrong. Hetzner's stable `5` matching a
# 5-core box was coincidence.
#
# Nothing was mis-collected — Conductor never collected a core count at all.
class ServerMetricsCpuTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cpu@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  def parse(output) = ServerMetrics.new(@server).send(:parse_metrics, output)

  test "the probe asks the HOST for physical cores, not a cgroup-limited count" do
    cmd = ServerMetrics::METRICS_COMMAND

    assert_match(/nproc --all/, cmd,
                 "plain `nproc` reports the cgroup/affinity count inside a container")
    assert_match(/CORES:/, cmd)
  end

  test "cores are parsed as static inventory, separate from utilisation" do
    m = parse("CPU:12.5\nCORES:6\nLOAD:0.4\n")

    assert_equal 6, m[:cpu_cores], "6 physical cores"
    assert_equal 13, m[:cpu_percent], "12.5% busy — a different quantity entirely"
  end

  # "A wrong core count is worse than a missing one — it's confidently misleading."
  test "an unreadable core count is nil, never a fabricated 0" do
    assert_nil parse("CPU:5\nCORES:\n")[:cpu_cores]
    assert_nil parse("CPU:5\nCORES:0\n")[:cpu_cores]
    assert_nil parse("CPU:5\n")[:cpu_cores], "absent means unknown"
  end

  test "a nonsense core count is refused rather than stored" do
    assert_nil parse("CPU:5\nCORES:-2\n")[:cpu_cores]
    assert_nil parse("CPU:5\nCORES:banana\n")[:cpu_cores]
  end

  # A sample must never overwrite inventory: a probe that failed to read cores
  # should leave the last known value alone rather than blanking it.
  def sample(**overrides)
    { cpu_percent: 10, memory_used_mb: 100, memory_total_mb: 1000,
      disk_percent: 20, uptime_seconds: 999, load_average: 0.1 }.merge(overrides)
  end

  test "a later probe without cores does not erase a known core count" do
    @server.update_metrics!(sample(cpu_cores: 6))
    @server.update_metrics!(sample(cpu_percent: 40))

    assert_equal 6, @server.reload.cpu_cores, "inventory must survive a sample"
    assert_equal 40, @server.cpu_percent
  end

  test "a real change in cores is still recorded" do
    @server.update_metrics!(sample(cpu_cores: 2))
    @server.update_metrics!(sample(cpu_cores: 8))

    assert_equal 8, @server.reload.cpu_cores
  end
end
