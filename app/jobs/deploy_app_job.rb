class DeployAppJob < ApplicationJob
  queue_as :default

  def perform(deployment_id)
    deployment = Deployment.find(deployment_id)
    app = deployment.app
    deployer =
      case app.deploy_method
      when "native" then NativeDeployer.new(app, deployment)
      when "kamal"  then KamalDeployer.new(app, deployment)
      else AppDeployer.new(app, deployment)
      end
    deployer.deploy!
  end
end
