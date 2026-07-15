# Shared organization resolution for creation tools run over MCP.
#
# MCP runs as the first admin user (a system actor with no request session), so
# creation tools must pick an Organization to own the new resource. Callers may
# pass `organization_id` or `organization_slug` (the parameterized org name);
# otherwise we default to the user's first organization.
module OrgResolvable
  # Returns [organization, error_message]. On success error is nil.
  def resolve_organization(input)
    if (id = input["organization_id"]).present?
      org = Organization.find_by(id: id)
      return [ nil, "Organization not found: #{id}" ] unless org
      return [ nil, "Not authorized for that organization" ] unless org_allowed?(org)
      return [ org, nil ]
    end

    if (slug = input["organization_slug"]).present?
      org = Organization.all.find { |o| o.name.parameterize == slug.to_s }
      return [ nil, "Organization not found: #{slug}" ] unless org
      return [ nil, "Not authorized for that organization" ] unless org_allowed?(org)
      return [ org, nil ]
    end

    org = Current.organization || @user&.organizations&.first
    return [ nil, "No organization available for this user" ] unless org
    [ org, nil ]
  end

  private

  # Which orgs an actor may create resources in.
  #  - A nil user is a trusted internal/system actor → any org.
  #  - An org-bound API token (Current.org_scoped) confines EVERY actor, admin
  #    included, to that one org — an org-A token must not create in org B.
  #  - Otherwise admins are global (legacy shared token / web session); a plain
  #    per-user token may only target orgs it belongs to.
  def org_allowed?(org)
    return true if @user.nil?
    return org.id == Current.organization&.id if Current.org_scoped
    return true if @user.admin?
    return org.id == Current.organization.id if Current.organization
    @user.organizations.exists?(org.id)
  end
end
