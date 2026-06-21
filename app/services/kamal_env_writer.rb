# Bridges Conductor's per-app env vars into a Kamal deploy.
#
# A repo's committed `.kamal/secrets` is references-only (e.g. `$DATABASE_PASSWORD`,
# `$(cat config/master.key)`) and safe for git — it carries no values. For a
# normal app those references can't resolve in Conductor's container, so
# KamalDeployer regenerates `.kamal/secrets` from the app's EnvVariables: Conductor
# (UI / the `conductor_app_config` set_env MCP tool) is the source of truth for the
# secret VALUES. (Self-deploys are the exception — they reuse the committed file,
# which resolves from Conductor's own env; see KamalDeployer#write_secrets_file.)
# The app's committed `deploy.yml` still declares WHICH keys to inject.
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
