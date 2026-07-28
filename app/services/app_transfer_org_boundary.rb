# The org boundary for an app transfer (spec 26). One rule, applied wherever a
# transfer is decided or executed — the same shape as OperatorPolicy.
#
# A transfer moves an app, its database, and its DNS onto another server. None of
# that may cross an organization boundary: the target server — and therefore the
# database cluster and credentials the transfer will use — must belong to the same
# org as the app.
#
# Why this lives in the services and not only at lookup: the MCP tool resolves both
# sides through ActorScoped, which confines an org-bound caller to its own org. But
# `ActorScoped#actor_admin?` is true for an actor with NO bound org — exactly the
# legacy shared CONDUCTOR_MCP_TOKEN, which runs as the first admin with global
# scope. For that caller `visible_apps`/`visible_servers` are `App.all`/`Server.all`,
# so a cross-org transfer is reachable. Any future caller that skips the tool layer
# (a controller, a job, the console) has the same exposure. So the invariant is
# enforced where the mutation is decided, and again where it is executed — the plan
# an operator reviewed can be stale by the time the runner acts on it.
module AppTransferOrgBoundary
  module_function

  # Raises `error` unless the app and its target server share an organization.
  # An app with no organization is refused outright: an unowned app has no boundary
  # to check, and silently allowing it would be the widest possible hole.
  def enforce!(app:, target_server:, error: StandardError)
    app_org = app&.organization_id
    target_org = target_server&.organization_id

    raise error, "#{app&.slug || 'app'} has no organization; refusing to transfer it" if app_org.nil?
    raise error, "target server has no organization; refusing to transfer #{app.slug} onto it" if target_org.nil?
    return true if app_org == target_org

    raise error,
          "cross-organization transfer refused: #{app.slug} belongs to #{app.organization.name}, " \
          "but #{target_server.name} belongs to #{target_server.organization.name}"
  end
end
