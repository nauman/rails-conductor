class FleetStatusTool
  include ActorScoped

  DEFINITION = {
    name: 'fleet_status',
    description: 'List all servers in the fleet with their current status, apps, and health metrics.',
    input_schema: {
      type: 'object',
      properties: {
        organization_id: {
          type: 'integer',
          description: 'Optional: scope the fleet to a single organization (admin-global, all servers, when omitted)'
        }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input = {})
    servers = visible_servers.includes(:apps, :script_runs)
    # Optional org scoping: keeps admin-global behavior by default.
    servers = servers.where(organization_id: input['organization_id']) if input['organization_id'].present?

    data = servers.map do |server|
      {
        id:          server.id,
        name:        server.name,
        ip:          server.ip_address,
        status:      server.status,
        provider:    server.provider,
        cpu:         server.cpu_percent,
        memory:      server.formatted_memory,
        disk:        server.disk_percent,
        last_seen:   server.last_seen_at&.strftime('%Y-%m-%d %H:%M UTC'),
        apps:        server.apps.map { |a| { name: a.name, status: a.status, domain: a.domain, notes: a.notes } }
      }
    end

    Result.ok(data)
  end
end
