class DeployAppTool
  DEFINITION = {
    name: 'deploy_app',
    description: 'Deploy an app by running the app-deploy script on its server.',
    input_schema: {
      type: 'object',
      properties: {
        app_id: {
          type: 'integer',
          description: 'The ID of the app to deploy'
        },
        app_name: {
          type: 'string',
          description: 'The name of the app to deploy (alternative to app_id)'
        }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Provide app_id or app_name.") unless app
    return Result.fail("App '#{app.name}' has no server assigned.") unless app.server

    script = Script.find_by(name: 'app-deploy')
    return Result.fail("Script 'app-deploy' not found. Run seeds to install built-in scripts.") unless script

    run = ScriptRun.create!(server: app.server, script: script, user: @user)
    ScriptRunJob.perform_later(run.id)

    Result.ok({
      script_run_id: run.id,
      app:           app.name,
      server:        app.server.name,
      status:        'started',
      message:       "Deploying #{app.name} on #{app.server.name}. ScriptRun ID: #{run.id}"
    })
  rescue ActiveRecord::RecordInvalid => e
    Result.fail(e.message)
  end

  private

  def find_app(input)
    return App.find_by(id: input['app_id']) if input['app_id'].present?
    App.find_by(name: input['app_name']) if input['app_name'].present?
  end
end
