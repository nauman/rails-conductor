# Per-app deploy runbook + checklist. A cohesive single-domain tool: every
# action resolves an app (or a checklist item scoped to a visible app) and shares
# the same params, so it dispatches internally rather than via separate leaf
# classes. The wire surface stays a flat `action`-enum tool.
class ConductorRunbookTool
  include ActorScoped

  DEFINITION = {
    name: "conductor_runbook",
    description: "Per-app deploy runbook + checklist — each app deploys differently, so " \
      "read this BEFORE deploying an app. Set `action` to one of: " \
      "get (return the runbook + checklist — app_id/app_name), " \
      "set_runbook (replace the markdown runbook — app_id/app_name, runbook), " \
      "add_item (append a checklist step — app_id/app_name, content, optional required), " \
      "remove_item (delete a step — item_id), " \
      "check_item (mark a step done or not — item_id, optional done=true), " \
      "reset (clear every done flag, e.g. before a new deploy — app_id/app_name).",
    input_schema: {
      type: "object",
      properties: {
        action:   { type: "string", enum: %w[get set_runbook add_item remove_item check_item reset], description: "Which runbook operation" },
        app_id:   { type: "integer", description: "target app by id" },
        app_name: { type: "string",  description: "target app by name" },
        runbook:  { type: "string",  description: "set_runbook: the full markdown runbook body" },
        content:  { type: "string",  description: "add_item: the checklist step text" },
        required: { type: "boolean", description: "add_item: whether the step is required (default true)" },
        item_id:  { type: "integer", description: "remove_item/check_item: the checklist item id" },
        done:     { type: "boolean", description: "check_item: mark done (default true) or undone (false)" }
      },
      required: %w[action]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    case input["action"]
    when "get"         then show(input)
    when "set_runbook" then set_runbook(input)
    when "add_item"    then add_item(input)
    when "remove_item" then remove_item(input)
    when "check_item"  then check_item(input)
    when "reset"       then reset(input)
    else
      Result.fail("Missing or unknown action '#{input['action']}'. Set action to one of: get, set_runbook, add_item, remove_item, check_item, reset.")
    end
  end

  private

  def show(input)
    app = find_app(input) or return app_not_found(input)
    ok(app, "Runbook for #{app.name}.")
  end

  def set_runbook(input)
    app = find_app(input) or return app_not_found(input)
    app.update!(deploy_runbook: input["runbook"].to_s)
    ok(app, "Runbook updated for #{app.name}.")
  end

  def add_item(input)
    app = find_app(input) or return app_not_found(input)
    content = input["content"].to_s.strip
    return Result.fail("content is required to add a checklist item.") if content.empty?

    item = app.deploy_checklist_items.create!(content: content, required: input.fetch("required", true))
    ok(app, "Added checklist step ##{item.id} to #{app.name}.")
  end

  def remove_item(input)
    item = find_item(input) or return Result.fail("Checklist item not found: #{input['item_id']}")
    app = item.app
    item.destroy!
    ok(app, "Removed checklist step from #{app.name}.")
  end

  def check_item(input)
    item = find_item(input) or return Result.fail("Checklist item not found: #{input['item_id']}")
    input.fetch("done", true) ? item.check!(user: @user) : item.uncheck!
    ok(item.app, "Checklist step #{item.done ? 'checked' : 'unchecked'} on #{item.app.name}.")
  end

  def reset(input)
    app = find_app(input) or return app_not_found(input)
    app.deploy_checklist_items.update_all(done: false, done_at: nil)
    ok(app.reload, "Checklist reset for #{app.name}.")
  end

  # A checklist item, scoped to apps this actor may touch (cross-tenant safe).
  def find_item(input)
    return nil if input["item_id"].blank?

    DeployChecklistItem.where(app_id: visible_apps.select(:id)).find_by(id: input["item_id"])
  end

  def app_not_found(input)
    Result.fail("App not found: #{input['app_id'] || input['app_name']}")
  end

  def ok(app, message)
    Result.ok(app.runbook_summary.merge(
      app_id:        app.id,
      app:           app.name,
      message:       message,
      _organization: app.organization || app.server&.organization
    ))
  end
end
