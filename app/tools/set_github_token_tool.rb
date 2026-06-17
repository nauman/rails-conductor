class SetGithubTokenTool
  include OrgResolvable

  DEFINITION = {
    name: 'set_github_token',
    description: "Store a GitHub API token for an org (a fine-grained PAT with Administration: read/write, or a GitHub App installation token). Conductor uses it to auto-manage deploy keys (and later webhooks) on the org's repos — so no manual GitHub steps.",
    input_schema: {
      type: 'object',
      properties: {
        token:             { type: 'string', description: 'The GitHub token' },
        organization_id:   { type: 'integer', description: 'Org id (optional; defaults to the caller org)' },
        organization_slug: { type: 'string',  description: 'Org slug (optional)' }
      },
      required: [ 'token' ]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    return Result.fail("token is required") if input["token"].blank?

    org, err = resolve_organization(input)
    return Result.fail(err) unless org

    cred = org.credentials.for_provider("github").first_or_initialize
    cred.assign_attributes(name: "GitHub", api_key: input["token"], active: true)
    return Result.fail(cred.errors.full_messages.join(", ")) unless cred.save

    Result.ok({
      organization:  org.name,
      provider:      "github",
      configured:    true,
      message:       "GitHub token stored for #{org.name}. Deploy keys will now be auto-installed on repos.",
      _organization: org
    })
  end
end
