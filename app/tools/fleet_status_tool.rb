class FleetStatusTool
  DEFINITION = {
    name: 'fleet_status',
    description: 'List all servers in the fleet with their current status, apps, and health metrics.',
    input_schema: {
      type: 'object',
      properties: {},
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(_input)
    servers = Server.all.includes(:apps, :script_runs)

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
