# WHAT DOES THIS APP STILL NEED BEFORE IT CAN DEPLOY — and who can supply it.
#
# First install was the case nothing answered. DeployPreflight assumes a deployable
# app; a brand-new one fails inside the deploy with "Missing required env var(s)"
# after a clone and a build, which is late and hard to act on.
#
# Over MCP it is worse than late. An agent that discovers a missing registry
# password has exactly one move it must NOT make: ask the operator to paste it into
# the conversation, where the answer becomes part of a transcript. So this tool
# reports NAMES and never values, and every item says how to supply it through a
# channel that is not a chat.
#
# It also separates what a human must supply from what Conductor derives itself.
# Asking someone for a database password Conductor is about to generate wastes their
# time and invites them to invent one that then disagrees with the real one.
class AppReadinessTool
  include ActorScoped

  DEFINITION = {
    name: "app_readiness",
    description: "What an app still needs before it can deploy: missing credential NAMES (never " \
                 "values), which of them Conductor supplies itself, and how to provide the rest " \
                 "without putting a secret in a conversation. Read-only. Use before a first deploy.",
    input_schema: {
      type: "object",
      properties: {
        app_id:   { type: "integer", description: "target app by id" },
        app_name: { type: "string",  description: "target app by name" }
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

    missing = missing_items(app)
    Result.ok({
      app: app.name,
      deploy_method: app.deploy_method,
      missing: missing,
      derived_by_conductor: derived_keys(app),
      summary: summarise(app, missing),
      _organization: app.organization
    })
  end

  private

  # Only what an operator must act on. A key Conductor derives is deliberately
  # absent rather than listed-and-excused: a list of things you cannot do anything
  # about trains people to skim the list.
  def missing_items(app)
    held = app.env_variables.map(&:key).to_set
    derived = derived_keys(app).to_set

    required_keys(app).reject { |k| held.include?(k) || derived.include?(k) }.map do |key|
      { key: key, why: reason_for(key, app), supply: supply_route(key, app) }
    end
  end

  # What Conductor injects without being told — see App#deploy_env_pairs. Chiefly a
  # dedicated database's DATABASE_URL, which Conductor provisions and therefore
  # already knows.
  def derived_keys(app)
    app.deploy_env_pairs(server: app.server).map(&:first) - app.env_variables.map(&:key)
  rescue StandardError
    []
  end

  def required_keys(app)
    keys = [ "RAILS_MASTER_KEY" ]
    keys << "KAMAL_REGISTRY_PASSWORD" if app.kamal?
    keys << "DATABASE_URL" unless app.dedicated_db?
    keys.uniq
  end

  def reason_for(key, app)
    case key
    when "RAILS_MASTER_KEY"
      "unlocks the app's own credentials — with it, every other secret the app needs stays in " \
      "config/credentials.yml.enc and never reaches Conductor at all (ADR 0016)"
    when "KAMAL_REGISTRY_PASSWORD"
      "Kamal pushes the built image to the registry and the target pulls it back"
    when "DATABASE_URL"
      "this app is not on a Conductor-provisioned database, so Conductor cannot derive its " \
      "connection string"
    else
      "declared by the app's deploy configuration"
    end
  end

  # Never "give it to me". Every route here is a channel that does not become a
  # conversation transcript.
  def supply_route(key, app)
    case key
    when "RAILS_MASTER_KEY"
      "the app's Environment Variables page, marked sensitive — the value is in the repo's " \
      "config/master.key, or your vault if it was seeded there"
    when "KAMAL_REGISTRY_PASSWORD"
      "store a registry token once with conductor_github action=set_token, or add it on the " \
      "Environment Variables page marked sensitive"
    when "DATABASE_URL"
      "either provision a database (conductor_database action=provision with app_id and no name, " \
      "so Conductor derives and holds it), or add the existing URL on the Environment Variables " \
      "page marked sensitive"
    else
      "the app's Environment Variables page, marked sensitive"
    end
  end

  def summarise(app, missing)
    return "#{app.name} has the credentials it needs — ready to deploy." if missing.empty?

    "#{app.name} needs #{missing.size} more #{'credential'.pluralize(missing.size)}: " \
    "#{missing.map { |m| m[:key] }.join(', ')}. Supply them through the routes listed — " \
    "do not ask for a secret in conversation, and do not paste one into a tool call."
  end
end
