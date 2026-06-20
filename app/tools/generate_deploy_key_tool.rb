class GenerateDeployKeyTool
  include ActorScoped

  DEFINITION = {
    name: 'generate_deploy_key',
    description: "Generate a read-only SSH deploy key for an app's private repo. Returns the PUBLIC key to add to the repo's GitHub deploy keys (Settings → Deploy keys, read-only). The private key is stored encrypted and used by Conductor to clone the repo.",
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

    key = DeployKey.generate_for(app)
    install = GithubDeployKeyInstaller.install(app)

    message = if install[:installed]
      "Deploy key generated AND added to #{install[:repo]} via GitHub integration. Ready to deploy."
    else
      "Deploy key generated for #{app.name}. Not auto-added (#{install[:reason]}) — add the public_key to the repo's GitHub deploy keys (read-only), or configure a GitHub token with set_github_token."
    end

    Result.ok({
      app:               app.name,
      public_key:        key.public_key,
      fingerprint:       key.fingerprint,
      github_installed:  install[:installed],
      github_detail:     install[:installed] ? install[:repo] : install[:reason],
      add_to:            "https://github.com/#{repo_path(app)}/settings/keys/new",
      message:           message,
      _organization:     app.organization || app.server&.organization
    })
  rescue DeployKeyGenerator::Error => e
    Result.fail("Could not generate deploy key: #{e.message}")
  end

  private

  def repo_path(app)
    app.repository_url.to_s[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?/?\z}, 1] || "OWNER/REPO"
  end

end
