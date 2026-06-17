class UpdateAppTool
  include OrgResolvable

  DEFINITION = {
    name: 'update_app',
    description: "Update an app's configuration (deploy method, repository, branch, domain, port, notes).",
    input_schema: {
      type: 'object',
      properties: {
        app_id:         { type: 'integer', description: 'App id (or use app_name)' },
        app_name:       { type: 'string',  description: 'App name (or use app_id)' },
        deploy_method:  { type: 'string',  description: 'One of: docker, native, kamal' },
        repository_url: { type: 'string',  description: 'Git repository URL' },
        branch:         { type: 'string',  description: 'Deploy branch' },
        domain:         { type: 'string',  description: 'Public domain' },
        port:           { type: 'integer', description: 'App port' },
        notes:          { type: 'string',  description: 'Free-form deploy notes (surfaced in fleet_status + API)' }
      },
      required: []
    }
  }.freeze

  UPDATABLE = %w[deploy_method repository_url branch domain port notes].freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    attrs = UPDATABLE.each_with_object({}) { |k, h| h[k] = input[k] if input.key?(k) }
    return Result.fail("Nothing to update. Provide at least one field.") if attrs.empty?

    if attrs.key?("deploy_method") && !App::DEPLOY_METHODS.include?(attrs["deploy_method"])
      return Result.fail("Invalid deploy_method: #{attrs['deploy_method']} (use docker, native, or kamal)")
    end

    return Result.fail(app.errors.full_messages.join(', ')) unless app.update(attrs)

    Result.ok({
      id:            app.id,
      app:           app.name,
      deploy_method: app.deploy_method,
      repository_url: app.repository_url,
      domain:        app.domain,
      notes:         app.notes,
      message:       "Updated #{app.name}.",
      _organization: app.organization || resolve_organization(input).first
    })
  end

  private

  def find_app(input)
    if input['app_id'].present?
      App.find_by(id: input['app_id'])
    elsif input['app_name'].present?
      App.find_by(name: input['app_name'])
    end
  end
end
