require "test_helper"

class RestartAppJobTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "restart@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "s", status: "online", ip_address: "10.0.0.1", ssh_key: key)
  end

  def app(method:)
    @org.apps.create!(name: "web-#{method}", slug: "web-#{method}", server: @server,
                      deploy_method: method, repository_url: "https://example.com/r.git",
                      status: "running", container_status: "exited")
  end

  # Records the command handed to #execute so we can assert HOW the restart is issued.
  def capturing_ssh(captured, output: "")
    Object.new.tap do |o|
      o.define_singleton_method(:execute) { |cmd| captured << cmd; @out = output; output }
      o.define_singleton_method(:success?) { true }
      o.define_singleton_method(:output) { @out }
      o.define_singleton_method(:error) { nil }
    end
  end

  test "a Kamal app is restarted by resolving its container via the service label, not conductor-<slug>" do
    a = app(method: "kamal")
    cmds = []
    SshConnection.stub(:new, ->(*) { capturing_ssh(cmds) }) do
      RestartAppJob.new.perform(a.id)
    end
    cmd = cmds.first
    assert_includes cmd, "label=service=", "Kamal restart must locate the container by service label"
    assert_includes cmd, 'docker restart "$cid"'
    # The fixed name may now appear as a FALLBACK for pre-ADR-0003 containers,
    # but it must never be what the command actually acts on.
    refute_includes cmd, "docker restart conductor-web-kamal",
                    "must not act on the conductor-<slug> name directly"
    assert cmd.index("label=service=$s") < cmd.index("name=^conductor-web-kamal$"),
           "the label lookup must be tried first"
  end

  # A zero-downtime deploy runs the app as app-<id>-r<rev>-<sha>, so a docker app
  # is no longer reliably reachable by its fixed name either.
  test "a docker app is restarted via its service label, falling back to the fixed name" do
    a = app(method: "docker")
    cmds = []
    SshConnection.stub(:new, ->(*) { capturing_ssh(cmds) }) do
      RestartAppJob.new.perform(a.id)
    end
    assert_includes cmds.first, "for s in app-#{a.id}"
    assert_includes cmds.first, "name=^conductor-web-docker$"
    assert_includes cmds.first, 'docker restart "$cid"'
  end

  test "NO_CONTAINER output is treated as a failed restart, not a success" do
    a = app(method: "kamal")
    SshConnection.stub(:new, ->(*) { capturing_ssh([], output: "NO_CONTAINER") }) do
      RestartAppJob.new.perform(a.id)
    end
    assert_equal "unknown", a.reload.container_status
    assert_match(/no container/i, a.status_check_error.to_s)
  end
end
