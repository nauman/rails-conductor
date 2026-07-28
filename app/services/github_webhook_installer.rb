# Installs an app's push webhook onto its GitHub repo via the org's GitHub token,
# pointing at Conductor's own webhook URL and HMAC-signed with the app's
# webhook_secret — so `git push` triggers a Conductor deploy with no manual
# GitHub steps. Mirrors GithubDeployKeyInstaller. No-op (with a reason) when
# there's no token or the repo isn't a parseable GitHub repo.
class GithubWebhookInstaller
  # host: Conductor's own public host (defaults to APP_HOST) — where the hook POSTs.
  def self.install(app, client: nil, host: nil)
    token = app.organization&.github_token
    return { installed: false, reason: "No GitHub token configured for this org" } if token.blank?

    repo = app.github_repo
    return { installed: false, reason: "Could not parse a GitHub repo from #{app.repository_url}" } if repo.blank?

    host ||= ENV.fetch("APP_HOST", "conductor.example.com")
    url = "https://#{host}#{app.webhook_path}"
    hook = (client || GithubClient.new(token)).create_webhook(repo: repo, url: url, secret: app.webhook_secret)

    { installed: true, repo: repo, webhook_url: url, hook_id: hook["id"] }
  rescue GithubClient::Error => e
    { installed: false, reason: e.message }
  end
end
