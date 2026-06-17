class DeploymentLogTool
  DEFINITION = {
    name: 'deployment_log',
    description: "Read a deployment's status and log output. Pass deployment_id, or app_id/app_name to get its latest deployment. Use to watch a deploy triggered via deploy_app.",
    input_schema: {
      type: 'object',
      properties: {
        deployment_id: { type: 'integer', description: 'Deployment id' },
        app_id:        { type: 'integer', description: "App id — returns the app's latest deployment" },
        app_name:      { type: 'string',  description: "App name — returns the app's latest deployment" },
        tail:          { type: 'integer', description: 'Return only the last N log lines (default: all)' }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    deployment = find_deployment(input)
    return Result.fail("Deployment not found. Provide deployment_id, app_id, or app_name.") unless deployment

    log = deployment.log.to_s
    if (n = input["tail"]).present?
      log = log.lines.last(n.to_i).join
    end
    app = deployment.app

    Result.ok({
      deployment_id: deployment.id,
      app:           app&.name,
      status:        deployment.status,
      commit_sha:    deployment.commit_sha,
      started_at:    deployment.started_at,
      completed_at:  deployment.completed_at,
      log:           log,
      _organization: app&.organization || app&.server&.organization
    })
  end

  private

  def find_deployment(input)
    if input["deployment_id"].present?
      Deployment.find_by(id: input["deployment_id"])
    elsif (app = find_app(input))
      app.deployments.order(created_at: :desc).first
    end
  end

  def find_app(input)
    if input["app_id"].present?
      App.find_by(id: input["app_id"])
    elsif input["app_name"].present?
      App.find_by(name: input["app_name"])
    end
  end
end
