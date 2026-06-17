class GithubInstallationsTool
  DEFINITION = {
    name: 'github_installations',
    description: "List the orgs/users where Conductor's GitHub App is installed (to verify access before deploying). Also accepts a repo to check whether the App can reach it.",
    input_schema: {
      type: 'object',
      properties: {
        repo: { type: 'string', description: 'Optional "owner/repo" to check reachability' }
      },
      required: []
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    gh = GithubApp.from_config
    return Result.fail("No GitHub App configured. Use set_github_app first.") unless gh

    if (repo = input["repo"]).present?
      id = gh.installation_id_for(repo)
      return Result.ok({ repo: repo, reachable: true, installation_id: id, message: "App can access #{repo}." })
    end

    Result.ok({ installations: gh.installations, message: "GitHub App installations." })
  rescue GithubApp::Error => e
    Result.fail(e.message)
  end
end
