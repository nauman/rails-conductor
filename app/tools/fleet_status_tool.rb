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
    servers = visible_servers.includes(:script_runs, apps: :deploy_checklist_items)
    # Optional org scoping: keeps admin-global behavior by default.
    servers = servers.where(organization_id: input['organization_id']) if input['organization_id'].present?

    data = servers.map do |server|
      {
        id:          server.id,
        name:        server.name,
        ip:          server.ip_address,
        status:      server.status,
        provider:    server.provider,
        # NOT a core count. This field was named `cpu` while carrying
        # UTILISATION, and capacity decisions were made on it: a 6-core box
        # reporting `cpu: 1` (1% busy) was read as a 1-core machine.
        cpu_percent: server.cpu_percent,
        cpu_cores:   server.cpu_cores, # nil = not yet read, never a guess
        memory:      server.formatted_memory,
        disk:        server.disk_percent,
        load:        server.load_average&.to_f,
        uptime:      server.formatted_uptime,
        last_seen:   server.last_seen_at&.strftime('%Y-%m-%d %H:%M UTC'),
        edge:        server.edge_detected? ? { type: server.edge_type, detail: server.edge_detail } : nil,
        apps:        server.apps.map { |a| { name: a.name, status: a.status, domain: a.domain, notes: a.notes, runbook: a.deploy_runbook.present?, checklist: a.runbook_summary[:checklist_progress] } }
      }
    end

    Result.ok(data)
  end
end
