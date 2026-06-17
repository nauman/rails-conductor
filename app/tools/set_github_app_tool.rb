class SetGithubAppTool
  DEFINITION = {
    name: 'set_github_app',
    description: "Configure Conductor's GitHub App (app_id + PEM private key). Once set, and the App installed on your org(s), Conductor mints installation tokens to clone/pull any accessible repo — no per-repo deploy keys, works across orgs. Stored Conductor-wide.",
    input_schema: {
      type: 'object',
      properties: {
        app_id:      { type: 'string', description: 'The GitHub App ID' },
        private_key: { type: 'string', description: 'The App private key (PEM, BEGIN/END RSA PRIVATE KEY)' }
      },
      required: [ 'app_id', 'private_key' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    return Result.fail("app_id and private_key are required") if input["app_id"].blank? || input["private_key"].blank?

    # Validate the key parses before storing.
    begin
      OpenSSL::PKey::RSA.new(input["private_key"])
    rescue OpenSSL::PKey::RSAError => e
      return Result.fail("private_key is not a valid PEM RSA key: #{e.message}")
    end

    cred = Credential.for_provider("github_app").first_or_initialize
    cred.assign_attributes(name: "GitHub App", organization: nil, api_key: input["app_id"], api_secret: input["private_key"], active: true)
    return Result.fail(cred.errors.full_messages.join(", ")) unless cred.save

    Result.ok({ provider: "github_app", app_id: input["app_id"], configured: true,
                message: "GitHub App configured. Install it on your org(s), then deploys can clone any accessible repo." })
  end
end
