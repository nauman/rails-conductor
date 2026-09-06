# Capability rules for the MCP surface, expressed per tool + ACTION (and, where
# it matters, per input field).
#
# Why not per tool: the wire surface is a set of flat `action`-enum tools, so the
# most dangerous operations sit inside tools an editor legitimately needs.
# `conductor_app` carries `deploy` (editor-safe) next to `retire`, `transfer`,
# and `runner` (owner-only). Gating the tool would block deploys; gating nothing
# would hand editors a production shell. So the unit of authorization is the
# action, resolved BEFORE the handler runs.
#
# Two independent questions, in order:
#
#   read_only?(tool, action)  — may a `read`-scoped token call this at all?
#   capability(tool, action, input) — which OperatorPolicy capability is needed?
module ToolAuthorization
  module_function

  # Non-mutating actions, per tool. A read-scoped token may call exactly these.
  # Previously this was a whole-tool list, which wrongly refused read tokens the
  # read-only actions living inside mutating tools (transfer_plan, cron list,
  # runbook get, storage audit).
  #
  # The bar for entry is "changes nothing" — not "feels like a read". An action
  # that opens SSH or writes a row belongs in the mutating set even if its name
  # sounds observational.
  READ_ONLY_ACTIONS = {
    "conductor_read"     => :all,
    "conductor_app"      => %w[transfer_plan],
    # NB: server `audit` and `test_connection` are deliberately NOT here — both
    # open SSH and persist (metrics, edge detection, an audit rollup), so a
    # read-scoped token must not reach them.
    "conductor_cron"     => %w[list],
    "conductor_runbook"  => %w[get list_rituals get_ritual],
    "conductor_storage"  => %w[audit configure]
  }.freeze

  # Actions requiring an owner-only capability. Everything absent from this map
  # needs only `operator?` (owner or editor).
  OWNER_ONLY_ACTIONS = {
    "conductor_app" => {
      # Removes an app from a box / moves it between boxes.
      "retire" => :destroy, "transfer" => :destroy,
      # `rails runner` with arbitrary Ruby inside the live production container.
      "runner" => :execute,
      # Edge route changes, maintenance, live cutover, and redeploy are
      # production traffic/deployment mutations. Keep them owner-only so an
      # agent/editor cannot turn the edge action into an implicit deploy path.
      "edge" => :execute,
      # Persists a managed Credential built from the app's env.
      "convert_database" => :credentials
    },
    "conductor_server" => {
      "remove" => :destroy,
      # Arbitrary shell over the server's SSH identity; root-level host mutation.
      "run_script" => :execute, "harden" => :execute, "install_packages" => :execute,
      # Generates and stores an encrypted private key.
      "add_ssh_key" => :credentials,
      # Writes into a server's authorized_keys — it grants Conductor durable access
      # to a machine, which is a credentials operation however routine it looks.
      "repair_identity" => :credentials
    },
    "conductor_domain" => {
      "remove" => :destroy, "delete_dns" => :destroy, "remove_stray_proxy" => :destroy
    },
    "conductor_app_config" => {
      # Destroys the app's existing deploy key and stores a new private key.
      "gen_deploy_key" => :credentials
    },
    "conductor_github" => {
      # Creates/updates a Credential holding a GitHub token.
      "set_token" => :credentials
    },
    # A cron entry is a raw command installed into a real crontab — ad-hoc
    # execution however it is dressed up. Owner-only until an allowlisted-task
    # design exists (see docs/scenarios/sc-009-editor-role.md, Decision B).
    "conductor_cron" => {
      "schedule" => :execute, "update" => :execute, "set_enabled" => :execute,
      "remove" => :destroy
    }
  }.freeze

  # Input fields that escalate an otherwise editor-safe action.
  # `conductor_app update` is ordinary config editing — unless it flips
  # seed_on_next_deploy (runs db:seed in production on the next deploy) or
  # repoints the app at a different repository.
  FIELD_ESCALATIONS = {
    "conductor_app" => {
      "update" => { "seed_on_next_deploy" => :execute, "repository_url" => :repository }
    }
  }.freeze

  def read_only?(tool_name, action)
    allowed = READ_ONLY_ACTIONS[tool_name]
    return false if allowed.nil?

    allowed == :all || allowed.include?(action.to_s)
  end

  # The capability this call needs, or nil for "operator is enough".
  def capability_for(tool_name, action, input = {})
    action = action.to_s
    # De-escalation first: an action that is owner-only in general can be
    # operator-safe for a specific, allowlisted input (SC-009 Decision B).
    return nil if read_only_task_run?(tool_name, action, input)

    escalation = FIELD_ESCALATIONS.dig(tool_name, action)&.find { |field, _| input.key?(field) }&.last

    escalation || OWNER_ONLY_ACTIONS.dig(tool_name, action)
  end

  # `runner` is owner-only because it executes arbitrary Ruby in production. A
  # bare, allowlisted, READ-ONLY task is a different thing wearing the same
  # action name — an editor who can deploy should be able to ask whether
  # migrations are pending.
  #
  # Both conditions are required: no `ruby` payload at all, AND the task is on
  # the allowlist. Passing both is rejected by the tool itself, but this must not
  # depend on that.
  def read_only_task_run?(tool_name, action, input)
    return false unless tool_name == "conductor_app" && action == "runner"
    return false if input["ruby"].to_s.strip.present?

    ReadOnlyRailsTasks.allow?(input["task"])
  end
end
