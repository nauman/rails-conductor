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
  # runbook get, storage audit, server audit).
  READ_ONLY_ACTIONS = {
    "conductor_read"     => :all,
    "conductor_app"      => %w[transfer_plan],
    "conductor_server"   => %w[audit test_connection],
    "conductor_cron"     => %w[list],
    "conductor_runbook"  => %w[get],
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
      # Persists a managed Credential built from the app's env.
      "convert_database" => :credentials
    },
    "conductor_server" => {
      "remove" => :destroy,
      # Arbitrary shell over the server's SSH identity; root-level host mutation.
      "run_script" => :execute, "harden" => :execute, "install_packages" => :execute,
      # Generates and stores an encrypted private key.
      "add_ssh_key" => :credentials
    },
    "conductor_domain" => {
      "remove" => :destroy, "delete_dns" => :destroy, "remove_stray_proxy" => :destroy
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
    escalation = FIELD_ESCALATIONS.dig(tool_name, action)&.find { |field, _| input.key?(field) }&.last

    escalation || OWNER_ONLY_ACTIONS.dig(tool_name, action)
  end
end
