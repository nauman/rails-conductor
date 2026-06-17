# Auto-installs an app's deploy key onto its GitHub repo via the org's GitHub
# token, so operators never paste keys into the GitHub UI. No-op (with a reason)
# when there's no token or the repo isn't a parseable GitHub repo.
class GithubDeployKeyInstaller
  def self.install(app, client: nil)
    return { installed: false, reason: "App has no deploy key" } unless app.deploy_key

    token = app.organization&.github_token
    return { installed: false, reason: "No GitHub token configured for this org" } if token.blank?

    repo = app.github_repo
    return { installed: false, reason: "Could not parse a GitHub repo from #{app.repository_url}" } if repo.blank?

    (client || GithubClient.new(token)).add_deploy_key(
      repo: repo, title: "conductor-#{app.slug}", key: app.deploy_key.public_key, read_only: true
    )
    { installed: true, repo: repo }
  rescue GithubClient::Error => e
    { installed: false, reason: e.message }
  end
end
