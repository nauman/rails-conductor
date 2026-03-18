class DeployAppJob < ApplicationJob
  queue_as :default

  def perform(deployment_id)
    deployment = Deployment.find(deployment_id)
    app = deployment.app
    deployer = app.native? ? NativeDeployer.new(app, deployment) : AppDeployer.new(app, deployment)
    deployer.deploy!
  end
end
