class SyncAppStatusTool
  include ActorScoped

  DEFINITION = {
    name: 'sync_app_status',
    description: "Check an app's live container status on its server (SSH) and update Conductor's record. Works for docker, native, and kamal apps.",
    input_schema: {
      type: 'object',
      properties: {
        app_id:   { type: 'integer', description: 'App id (or use app_name)' },
        app_name: { type: 'string',  description: 'App name (or use app_id)' }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app
    return Result.fail("App '#{app.name}' can't be status-synced (needs a server with SSH).") unless app.can_sync_status?

    service = ContainerStatus.new(app)
    service.sync!
    app.reload

    Result.ok({
      app:              app.name,
      deploy_method:    app.deploy_method,
      status:           app.status,
      container_status: app.container_status,
      synced:           service.success?,
      error:            service.error,
      message:          "#{app.name} is #{app.status} (container: #{app.container_status}).",
      _organization:    app.organization || app.server&.organization
    })
  end

  private

end
