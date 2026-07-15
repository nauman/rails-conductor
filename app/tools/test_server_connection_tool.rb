# Verify Conductor can actually reach a server over SSH, and if so refresh its
# metrics so status/last_seen stop reading "pending". This is the MCP equivalent
# of the "Test connection" button, so an agent can confirm connectivity after
# attaching a key without a human in the loop.
class TestServerConnectionTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    ssh = SshConnection.new(server)
    # A failed probe is a failure — return Result.fail so the MCP layer reports
    # isError:true and doesn't log a successful call for a broken connection.
    return Result.fail("SSH connection to #{server.name} failed: #{ssh.error}") unless ssh.test

    # Connected — pull metrics so the fleet stops showing this host as pending.
    refreshed = ServerMetrics.new(server).fetch_and_update!
    server.reload

    Result.ok({
      server:            server.name,
      connected:         true,
      status:            server.display_status,
      last_seen:         server.last_seen_at,
      metrics_refreshed: refreshed,
      message:           "SSH connection to #{server.name} succeeded.",
      _organization:     server.organization
    })
  end
end
