class GenerateDeployKeyTool
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

    Result.ok({
      app:            app.name,
      public_key:     key.public_key,
      fingerprint:    key.fingerprint,
      add_to:         "https://github.com/#{repo_path(app)}/settings/keys/new",
      message:        "Deploy key generated for #{app.name}. Add the public_key to the repo's GitHub deploy keys (read-only), then deploy.",
      _organization:  app.organization || app.server&.organization
    })
  rescue DeployKeyGenerator::Error => e
    Result.fail("Could not generate deploy key: #{e.message}")
  end

  private

  def repo_path(app)
    app.repository_url.to_s[%r{[:/]([^/:]+/[^/]+?)(?:\.git)?/?\z}, 1] || "OWNER/REPO"
  end

  def find_app(input)
    if input['app_id'].present?
      App.find_by(id: input['app_id'])
    elsif input['app_name'].present?
      App.find_by(name: input['app_name'])
    end
  end
end
