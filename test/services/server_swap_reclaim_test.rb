require "test_helper"

class ServerSwapReclaimTest < ActiveSupport::TestCase
  # Records every command; replies are keyed by a substring of the command so a
  # test can make the readiness probe succeed and the wrapper fail (the exact
  # shape of a server granted before the wrapper existed).
  class ScriptedSsh
    attr_reader :ran

    def initialize(replies = {})
      @replies = replies
      @ran = []
    end

    attr_accessor :replies

    # Match the EXACT privileged invocation for wrapper keys. Substring matching
    # also caught the wrapper inventory (which lists every wrapper path), so a
    # reply meant for one command was answering two.
    def execute_with_status(cmd)
      @ran << cmd
      _, reply = @replies.find do |fragment, _|
        f = fragment.to_s
        f.start_with?("/usr/local/sbin/") ? cmd == "sudo -n #{f}" : cmd.include?(f)
      end
      reply || { success: true, exit_code: 0, stdout: "", stderr: "" }
    end
  end

  setup do
    user = User.create!(email: "swap@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  test "runs the vetted wrapper and reports what it reclaimed" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: true, exit_code: 0, stdout: "reclaimed 2096508K\n", stderr: ""
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert result.success?
    assert_includes result.message, "2096508K"
    assert ssh.ran.any? { |c| c == "sudo -n #{ServerSudo::RECLAIM_SWAP}" },
           "expected the wrapper to run with no argument passthrough"
  end

  test "surfaces the wrapper's refusal rather than reporting success" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: false, exit_code: ServerSwapReclaim::REFUSED_EXIT_CODE,
      stdout: "", stderr: "refusing: 2096508K in swap but only 900000K available RAM\n"
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "not enough free RAM"
    assert_includes result.message, "900000K available"
  end

  # THE POINT OF THE REPAIR PATH. A box provisioned before this wrapper existed
  # must not send a human to a root login: HardenServer already granted the deploy
  # user NOPASSWD:ALL, so Conductor installs the missing wrapper itself and carries
  # on. Asking for root here was a design mistake, not a constraint.
  test "installs a missing wrapper itself instead of asking for root" do
    calls = 0
    ssh = ScriptedSsh.new
    # First inventory reports the wrapper missing; after the grant runs, it is there.
    ssh.define_singleton_method(:execute_with_status) do |cmd|
      @ran << cmd
      if cmd.start_with?("for w in")
        calls += 1
        next { success: true, exit_code: 0, stdout: (calls == 1 ? "#{ServerSudo::RECLAIM_SWAP}\n" : ""), stderr: "" }
      end
      { success: true, exit_code: 0, stdout: "reclaimed 2096508K\n", stderr: "" }
    end

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert result.success?, result.message
    assert ssh.ran.any? { |c| c.include?("/etc/sudoers.d/conductor") },
           "expected Conductor to install the wrapper set itself"
    assert ssh.ran.none? { |c| c.include?("root@") }, "must never reach for a root login"
  end

  test "falls back to the one-time grant only when self-repair fails" do
    ssh = ScriptedSsh.new("for w in" => {
      success: true, exit_code: 0, stdout: "#{ServerSudo::RECLAIM_SWAP}\n", stderr: ""
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "conductor-reclaim-swap"
    assert_includes result.message, "sudoers", "expected the one-time grant remediation"
  end

  # A box that cannot be reached is not a box that needs re-provisioning. Sending
  # an operator to a root setup block over a network blip is how a remediation
  # message stops being read at all.
  test "an unreachable host is not reported as a missing grant" do
    ssh = ScriptedSsh.new(ServerSudo::CHECK => {
      success: false, exit_code: 255, stdout: "", stderr: "ssh: connect to host 192.0.2.10 port 22: Connection timed out"
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "Cannot reach"
    assert_not_includes result.message, "sudoers"
  end

  # The failure mode codex caught: swapoff succeeded, swap did not come back. The
  # box is now WORSE off than before, and that must not read as a generic error.
  test "shouts when swap was disabled and could not be restored" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: false, exit_code: ServerSwapReclaim::SWAP_LOST_EXIT_CODE, stdout: "",
      stderr: "ERROR: swap is OFF after reclaim"
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "URGENT"
    assert_includes result.message, "no swap at all"
  end

  # A safety check that cannot read the box must fail CLOSED. Empty free(1) output
  # previously parsed as "0 in swap" and returned success having done nothing.
  test "an unreadable memory snapshot fails closed, not as a no-op success" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: false, exit_code: ServerSwapReclaim::UNREADABLE_EXIT_CODE, stdout: "",
      stderr: "unreadable memory figures from free(1)"
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "did not touch swap"
  end

  # The host lock is the only guard that survives the caller dying, so a refusal
  # from it is a correct outcome and must read as one — not as a generic failure
  # an operator would retry, which is precisely how a device gets shed.
  test "a concurrent reclaim is reported as a refusal, not a failure to retry" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: false, exit_code: ServerSwapReclaim::LOCKED_EXIT_CODE, stdout: "",
      stderr: "another reclaim is already running on this host"
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "already running"
    assert_includes result.message, "shed"
  end

  test "an in-flight reclaim blocks a second enqueue until it goes stale" do
    @server.update!(last_swap_reclaim_status: "running", last_swap_reclaim_at: Time.current)
    assert ServerSwapReclaim.in_flight?(@server)

    # A worker that died mid-job must not wedge the control forever.
    @server.update!(last_swap_reclaim_at: 20.minutes.ago)
    assert_not ServerSwapReclaim.in_flight?(@server)
  end

  # "The inventory did not run" and "nothing is missing" are opposite facts.
  test "a failed wrapper inventory is not read as a healthy box" do
    ssh = ScriptedSsh.new("for w in" => { success: false, exit_code: 255, stdout: "", stderr: "Connection timed out" })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "Cannot reach"
  end

  test "the wrapper takes a host lock before it touches swap" do
    command = ServerSudo.grant_command(@server)

    assert_includes command, "flock -n 9", "a Ruby-side check cannot stop another worker or a human on the box"
    assert_match(/set -e.*visudo -cf/m, command, "a failed visudo must stop the install that follows it")
  end

  test "refuses to build a sudoers grant for an unsafe account name" do
    @server.update_columns(ssh_user: "deploy\nroot ALL=(ALL) NOPASSWD:ALL")

    assert_raises(ServerSudo::UnsafeUser) { ServerSudo.grant_command(@server) }
  end

  # A missing grant is no longer a dead end: Conductor installs it with the deploy
  # user's own sudo and carries on. What must NOT happen is running the wrapper
  # when that repair failed — that would be a privileged op fired blind.
  test "does not run the wrapper when the grant is missing and cannot be repaired" do
    ssh = ScriptedSsh.new("" => { success: false, exit_code: 1, stdout: "", stderr: "sudo: a password is required" })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_not ssh.ran.any? { |c| c == "sudo -n #{ServerSudo::RECLAIM_SWAP}" },
               "must not fire a privileged op after repair failed"
  end

  test "reports the no-op honestly when swap is already empty" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: true, exit_code: 0, stdout: "swap already empty\n", stderr: ""
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert result.success?
    assert_includes result.message, "already empty"
  end

  test "the grant installs the reclaim wrapper and lists it in sudoers" do
    command = ServerSudo.grant_command(@server)

    assert_includes command, ServerSudo::RECLAIM_SWAP
    assert_includes command, "swapoff -a"
    assert_includes command, "swapon -a"
    assert_includes command, "/proc/swaps", "must restore the devices that were actually active"
    assert_includes command, "visudo -cf", "sudoers must be validated before it is installed"
    assert_match(/NOPASSWD:.*conductor-reclaim-swap/, command)
  end
end
