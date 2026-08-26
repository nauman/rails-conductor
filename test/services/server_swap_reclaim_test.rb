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

    def execute_with_status(cmd)
      @ran << cmd
      _, reply = @replies.find { |fragment, _| cmd.include?(fragment.to_s) }
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

  # The distinction that matters: a server granted before this wrapper shipped
  # passes the readiness probe (which only exercises conductor-check) and then
  # fails on the wrapper itself. That is a provisioning gap, not a swap problem,
  # and the operator needs the re-grant command — not "command not found".
  test "asks for a re-grant when the wrapper is not installed yet" do
    ssh = ScriptedSsh.new(ServerSudo::RECLAIM_SWAP => {
      success: false, exit_code: 1, stdout: "",
      stderr: "sudo: #{ServerSudo::RECLAIM_SWAP}: command not found"
    })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_includes result.message, "conductor-reclaim-swap"
    assert_includes result.message, "sudoers", "expected the one-time grant remediation"
  end

  test "refuses before touching the box when sudo is not granted at all" do
    ssh = ScriptedSsh.new(ServerSudo::CHECK => { success: false, exit_code: 1, stdout: "", stderr: "sudo: a password is required" })

    result = ServerSwapReclaim.new(@server, ssh: ssh).reclaim!

    assert_not result.success?
    assert_not ssh.ran.any? { |c| c.include?(ServerSudo::RECLAIM_SWAP) },
               "must not attempt the wrapper without a grant"
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
    assert_match(/NOPASSWD:.*conductor-reclaim-swap/, command)
  end
end
