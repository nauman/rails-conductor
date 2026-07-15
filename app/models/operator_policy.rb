# Single source of truth for "who may perform privileged infrastructure
# operations" — deploying, running scripts, changing config/env/credentials,
# provisioning — across every surface (web, API, MCP tools, jobs). Reading and
# viewing is open to any member; mutating/executing requires an organization
# owner or a platform admin.
#
# One policy, called everywhere, instead of per-controller action lists.
module OperatorPolicy
  module_function

  def operator?(user, organization)
    return false if user.nil?
    return true if user.admin?

    !!organization&.owner?(user)
  end
end
