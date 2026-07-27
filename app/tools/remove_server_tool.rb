# Remove (deregister) a server from the fleet. Destructive. Safer than the raw
# UI destroy: refuses if apps are still attached (they'd be detached via nullify)
# unless force:true. Scoped to servers the actor can see.
class RemoveServerTool
  include ActorScoped

  DEFINITION = {
    name: "remove_server",
    description: "Remove (deregister) a server from the fleet — server_id or server_name. " \
      "Refuses if apps are still attached unless force:true (they'd be detached). Destructive — confirm first.",
    input_schema: {
      type: "object",
      properties: {
        server_id:   { type: "integer", description: "Target server id" },
        server_name: { type: "string",  description: "Target server by name (alt to server_id)" },
        force:       { type: "boolean", description: "Remove even if apps are still attached (detaches them). Default false." }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found. Pass a valid server_id or server_name.") unless server

    app_count = server.apps.count
    if app_count.positive? && input["force"] != true
      return Result.fail("#{server.name} still has #{app_count} app(s) attached. Move/delete them first, or pass force:true to detach and remove anyway.")
    end

    name = server.name
    org = server.organization
    server.destroy

    Result.ok({ removed: true, server: name, detached_apps: app_count, _organization: org })
  end
end
