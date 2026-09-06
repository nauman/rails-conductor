# Install Conductor's own SSH key on a server that predates it doing so.
#
# Conductor used to generate a keypair and tell the operator to add the public half
# to their servers by hand — a manual errand documented as a feature. Registration
# now installs it, but every server registered before that still runs on whatever
# key happened to authorize root at the time, and a cross-box deploy fails there
# until a human edits authorized_keys.
#
# This is the repair, and it runs as the ORDINARY SSH USER. It needs no root, and
# it must not ask for any: the whole point is that the identity Conductor already
# holds is made to work, rather than a privileged credential being borrowed to
# paper over the fact that it does not.
class RepairServerIdentityTool
  include ActorScoped

  DEFINITION = {
    name: "repair_server_identity",
    description: "Install Conductor's own SSH key in the target's authorized_keys, then prove it " \
                 "authenticates. For servers registered before Conductor installed its key itself.",
    input_schema: {
      type: "object",
      properties: {
        server_id:   { type: "integer", description: "Server by id (or server_name)" },
        server_name: { type: "string",  description: "Server by name (or server_id)" }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    result = ServerIdentity.new(server).ensure!

    unless result.ok?
      # A refusal here names what is missing rather than suggesting a way around it.
      # "Add the key by hand" is the behaviour being removed, not a fallback.
      return Result.fail("Could not establish Conductor's identity on #{server.name}: #{result.reason}")
    end

    Result.ok({
      server: server.name,
      action: result.action,
      message: case result.action
               when "already-authorized"
                 "#{server.name} already authorizes Conductor's own key — verified by connecting with it."
               else
                 "Installed Conductor's key on #{server.name} for #{server.ssh_user_or_default} and " \
                 "verified it authenticates. Cross-box deploys to this server no longer depend on " \
                 "whichever key happened to reach root at registration."
               end,
      _organization: server.organization
    })
  end
end
