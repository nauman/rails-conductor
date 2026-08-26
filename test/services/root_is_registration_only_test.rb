require "test_helper"

# THE INVARIANT: root is a REGISTRATION-ONLY credential.
#
# Conductor stores no root credential. It logs in as the server's ssh_user, and
# HardenServer's PROVISION step grants that user `ALL=(ALL) NOPASSWD:ALL`. So after
# a box is registered there is no privileged operation the deploy user cannot
# perform, and therefore no honest reason to ask a human for root again.
#
# This is a test and not a doc because the mistake it guards against was made by
# reading the codebase and believing it. ServerSudo#remediation used to open with
# "Run this once as root", every caller trusted that instruction, and nothing
# anywhere asked the only question that mattered: had the deploy user's existing
# sudo been tried first? It had not. A rule that lives in prose gets re-derived and
# re-broken; a rule that fails the build does not.
#
# The bright line, chosen because it needs no judgement: root is permitted ONLY
# while no deploy user with sudo exists yet — i.e. registration and hardening.
# Everywhere else, escalation must be attempted with the identity Conductor already
# holds, and a human may be asked only after that attempt has actually failed.
class RootIsRegistrationOnlyTest < ActiveSupport::TestCase
  # Bootstrapping the deploy identity is the one thing that cannot use it.
  ROOT_IS_LEGITIMATE_IN = %w[
    app/services/harden_server.rb
    app/services/server_sudo.rb
  ].freeze

  ROOT_INSTRUCTION = /run (this )?(once )?as root|log ?in as root|ssh root@|sudo su\b/i

  setup do
    user = User.create!(email: "root-inv@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  test "no service tells an operator to become root outside registration" do
    offenders = Dir[Rails.root.join("app/**/*.rb")].filter_map do |path|
      relative = Pathname.new(path).relative_path_from(Rails.root).to_s
      next if ROOT_IS_LEGITIMATE_IN.include?(relative)

      line = File.readlines(path).each_with_index.find { |l, _| l.match?(ROOT_INSTRUCTION) }
      "#{relative}:#{line[1] + 1}" if line
    end

    assert_empty offenders,
                 "These ask a human for root outside registration. Conductor already holds an " \
                 "identity with NOPASSWD sudo on every provisioned box — route the escalation " \
                 "through ServerSudo.ensure! instead of asking a person:\n  #{offenders.join("\n  ")}"
  end

  # The specific regression: "the scoped sudoers file is missing" is NOT "this box
  # needs root". The broad provisioning grant may still be there, and it is what
  # lets Conductor install the scoped one itself.
  test "a missing grant is repaired with the deploy user's sudo, never escalated" do
    ran = []
    ssh = Object.new
    ssh.define_singleton_method(:execute_with_status) do |cmd|
      ran << cmd
      # conductor-check fails UNTIL the grant is installed — exactly a box that
      # still has 90-deploy but not /etc/sudoers.d/conductor. After repair it
      # works, which is what repair! now verifies rather than assuming.
      granted = ran.any? { |c| c.include?("/etc/sudoers.d/conductor") }
      next { success: false, exit_code: 1, stdout: "", stderr: "sudo: a password is required" } if cmd == "sudo -n /usr/local/sbin/conductor-check" && !granted

      { success: true, exit_code: 0, stdout: "", stderr: "" }
    end

    elevation = ServerSudo.ensure!(@server, ssh)

    assert elevation.usable?, "expected self-repair, got #{elevation.status}: #{elevation.detail}"
    assert ran.any? { |c| c.include?("/etc/sudoers.d/conductor") },
           "expected Conductor to install the grant itself"
    assert ran.none? { |c| c.match?(ROOT_INSTRUCTION) }, "must never shell out as root"
  end

  # And when the automated path genuinely cannot work, the operator is asked — but
  # only then, and the message has to say the attempt was already made so nobody
  # reads it as the first resort it used to be.
  test "an operator is asked only after self-repair has actually been attempted" do
    attempted = false
    ssh = Object.new
    ssh.define_singleton_method(:execute_with_status) do |cmd|
      attempted = true if cmd.include?("/etc/sudoers.d/conductor")
      { success: false, exit_code: 1, stdout: "", stderr: "sudo: a password is required" }
    end

    elevation = ServerSudo.ensure!(@server, ssh)

    assert elevation.needs_operator?
    assert attempted, "remediation must never be reached without trying the deploy user first"
    assert_match(/ALREADY TRIED/, elevation.detail)
  end

  # Registration is the exception, and it must stay narrow: HardenServer may use
  # root, but only because it prefers the deploy user whenever that already works.
  test "hardening prefers an existing sudo-capable deploy user over root" do
    source = File.read(Rails.root.join("app/services/harden_server.rb"))

    assert_match(/sudo -n true/, source,
                 "harden must probe the deploy user's sudo before falling back to root")
  end
end
