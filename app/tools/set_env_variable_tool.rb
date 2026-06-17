class SetEnvVariableTool
  include OrgResolvable

  DEFINITION = {
    name: 'set_env_variable',
    description: 'Set (create or update) an environment variable on an app.',
    input_schema: {
      type: 'object',
      properties: {
        app_id:   { type: 'integer', description: 'App id (or use app_name)' },
        app_name: { type: 'string',  description: 'App name (or use app_id)' },
        key:      { type: 'string',  description: 'Variable name (UPPER_SNAKE_CASE)' },
        value:    { type: 'string',  description: 'Variable value' },
        secret:   { type: 'boolean', description: 'Optional: mark the value as a secret (masked in the UI)' }
      },
      required: [ 'key', 'value' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app

    var = app.env_variables.find_or_initialize_by(key: input['key'])
    var.value = input['value']
    var.secret = input['secret'] if input.key?('secret')

    return Result.fail(var.errors.full_messages.join(', ')) unless var.save

    org = app.organization || resolve_organization(input).first

    Result.ok({
      id:            var.id,
      app_id:        app.id,
      app:           app.name,
      key:           var.key,
      secret:        var.secret,
      message:       "Environment variable #{var.key} set on #{app.name}.",
      _organization: org
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
