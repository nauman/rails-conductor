class RunScriptTool
  DEFINITION = {
    name: 'run_script',
    description: 'Run a provisioning or deployment script on a server. Creates a ScriptRun record and enqueues the job.',
    input_schema: {
      type: 'object',
      properties: {
        server_id: {
          type: 'integer',
          description: 'The ID of the server to run the script on'
        },
        script_name: {
          type: 'string',
          description: 'The name of the script to run (e.g. server-provision, ruby-install, app-setup, app-deploy, systemd-setup)'
        }
      },
      required: [ 'server_id', 'script_name' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = Server.find_by(id: input['server_id'])
    return Result.fail("Server not found: #{input['server_id']}") unless server

    script = Script.find_by(name: input['script_name'])
    return Result.fail("Script not found: #{input['script_name']}. Available: #{Script.pluck(:name).join(', ')}") unless script

    run = ScriptRun.create!(server: server, script: script, user: @user)
    ScriptRunJob.perform_later(run.id)

    Result.ok({
      script_run_id: run.id,
      server:        server.name,
      script:        script.name,
      status:        run.status,
      message:       "Script '#{script.name}' started on #{server.name}. ScriptRun ID: #{run.id}",
      # _organization: org this call touched; logged by the MCP controller, then stripped.
      _organization: server.organization
    })
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(e.message)
  end
end
