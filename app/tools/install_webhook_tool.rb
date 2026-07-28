# Wire push-to-deploy for an app in one call: install a GitHub push webhook
# (pointing at Conductor, HMAC-signed with the app's webhook_secret) AND enable
# auto_deploy. No manual GitHub steps. Mutating. Delegates to GithubWebhookInstaller.
class InstallWebhookTool
  include ActorScoped

  DEFINITION = {
    name: "install_webhook",
    description: "Wire push-to-deploy for an app: install a GitHub push webhook (pointing at Conductor, " \
      "signed with the app's secret) AND enable auto_deploy — one call, no manual GitHub steps. " \
      "Needs a GitHub token stored for the org (conductor_github action=set_token) and the app's repository_url.",
    input_schema: {
      type: "object",
      properties: {
        app_id:   { type: "integer", description: "target app by id" },
        app_name: { type: "string",  description: "target app by name" }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found. Pass a valid app_id or app_name.") unless app
    return Result.fail("#{app.name} has no repository_url set.") if app.repository_url.blank?

    r = GithubWebhookInstaller.install(app)
    return Result.fail("Webhook install failed: #{r[:reason]}") unless r[:installed]

    app.update!(auto_deploy: true)

    Result.ok({
      app: app.name,
      repo: r[:repo],
      webhook_url: r[:webhook_url],
      auto_deploy: true,
      message: "Push-to-deploy wired for #{app.name}: webhook on #{r[:repo]} + auto_deploy enabled.",
      _organization: app.organization
    })
  end
end
