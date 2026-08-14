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
      "remove_item (delete a step — app + item_id), " \
      "check_item (mark a step done or not — app + item_id, optional done=true), " \
      "evidence (attach execution evidence — app + item_id, kind, value), " \
      "reset (clear every done flag, e.g. before a new deploy — app_id/app_name).",
    input_schema: {
      type: "object",
      properties: {
        action:   { type: "string", enum: %w[get set_runbook add_item remove_item check_item evidence reset], description: "Which runbook operation" },
        app_id:   { type: "integer", description: "target app by id" },
        app_name: { type: "string",  description: "target app by name" },
        runbook:  { type: "string",  description: "set_runbook: the full markdown runbook body" },
        content:  { type: "string",  description: "add_item: the checklist step text" },
        required: { type: "boolean", description: "add_item: whether the step is required (default true)" },
        item_id:  { type: "string", description: "remove_item/check_item/evidence: opaque checklist item id; include app_id/app_name when ids repeat" },
        done:     { type: "boolean", description: "check_item: mark done (default true) or undone (false)" },
        kind:     { type: "string", description: "evidence: one of output, url, sha, count, or note" },
        value:    { type: "string", description: "evidence: the reference, URL, commit, or note" },
        expected_revision: { type: "string", description: "Revision returned by get; optional during the compatibility window" }
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
    when "evidence"    then evidence(input)
    when "reset"       then reset(input)
    else
      Result.fail("Missing or unknown action '#{input['action']}'. Set action to one of: get, set_runbook, add_item, remove_item, check_item, evidence, reset.")
    end
  end

  private

  def show(input)
    app = find_app(input) or return app_not_found(input)
    ok(app, "Runbook for #{app.name}.")
  end

  def set_runbook(input)
    app = find_app(input) or return app_not_found(input)
    AppRunbook.new(app, actor: @user).set_runbook(description: input["runbook"], expected_revision: input["expected_revision"])
    ok(app, "Runbook updated for #{app.name}.")
  end

  def add_item(input)
    app = find_app(input) or return app_not_found(input)
    content = input["content"].to_s.strip
    return Result.fail("content is required to add a checklist item.") if content.empty?

    AppRunbook.new(app, actor: @user).add_item(content: content, required: input.fetch("required", true), expected_revision: input["expected_revision"])
    ok(app, "Added checklist step to #{app.name}.")
  end

  def remove_item(input)
    app = find_app_for_item(input) or return item_lookup_failure(input)
    AppRunbook.new(app, actor: @user).remove_item(item_id: input["item_id"], expected_revision: input["expected_revision"])
    ok(app, "Removed checklist step from #{app.name}.")
  end

  def check_item(input)
    app = find_app_for_item(input) or return item_lookup_failure(input)
    result = AppRunbook.new(app, actor: @user).check_item(item_id: input["item_id"], done: input.fetch("done", true), expected_revision: input["expected_revision"])
    # The tick succeeded either way. When the open run could not record it, say so
    # in the SAME success response — an omission a caller cannot see is how a
    # partial outcome gets read as a total one.
    message = "Checklist step updated on #{app.name}."
    message += " Note: #{result.note}." unless result.recorded_in_run?
    ok(app, message)
  end

  def evidence(input)
    app = find_app_for_item(input) or return item_lookup_failure(input)
    return Result.fail("kind is required to attach evidence.") if input["kind"].to_s.strip.empty?
    return Result.fail("value is required to attach evidence.") if input["value"].to_s.strip.empty?

    AppRunbook.new(app, actor: @user).attach_evidence(item_id: input["item_id"],
                                                       kind: input["kind"], value: input["value"])
    ok(app, "Evidence attached to #{app.name}.")
  end

  def reset(input)
    app = find_app(input) or return app_not_found(input)
    AppRunbook.new(app, actor: @user).reset(expected_revision: input["expected_revision"])
    ok(app.reload, "Checklist reset for #{app.name}.")
  end

  # A checklist item, scoped to apps this actor may touch (cross-tenant safe).
  def find_app_for_item(input)
    @item_lookup_ambiguous = false
    return nil if input["item_id"].blank?

    if input["app_id"].present? || input["app_name"].present?
      app = find_app(input)
      return app if app && app_has_item?(app, input["item_id"])
      return nil
    end

    matches = visible_apps.select do |app|
      app.runbook_summary[:checklist].any? { |item| item[:id].to_s == input["item_id"].to_s }
    end
    @item_lookup_ambiguous = matches.many?
    matches.one? ? matches.first : nil
  end

  def app_has_item?(app, item_id)
    app.runbook_summary[:checklist].any? { |item| item[:id].to_s == item_id.to_s }
  end

  def item_lookup_failure(input)
    if @item_lookup_ambiguous
      Result.fail("Checklist item id is ambiguous: #{input['item_id']}. Include app_id or app_name.")
    else
      Result.fail("Checklist item not found: #{input['item_id']}")
    end
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
