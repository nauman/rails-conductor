# Bridges Conductor's per-app env vars into a Kamal deploy.
#
# A server-side `git clone` of the app repo does NOT include `.kamal/secrets`
# (it's gitignored), so KamalDeployer generates it from the app's EnvVariables.
# This makes Conductor's UI / the `set_env_variable` MCP tool the source of truth
# for a kamal app's secret VALUES (e.g. SECRET_KEY_BASE, DATABASE_URL). The app's
# committed `deploy.yml` still declares WHICH keys to inject under `env.secret`.
class KamalEnvWriter
  # dotenv-style KEY=value content for `.kamal/secrets`. One line per env var;
  # values are passed through verbatim (Kamal reads this file as dotenv).
  def self.secrets_content(app)
    lines = app.env_variables.order(:key).map { |v| "#{v.key}=#{v.value}" }
    (lines.join("\n") + "\n")
  end

  # The keys Conductor manages — handy for surfacing/validating the deploy.yml
  # `env.secret` declaration.
  def self.managed_keys(app)
    app.env_variables.order(:key).pluck(:key)
  end
end
