# Per-organization limits for `new` tenants (plan 02 § 5.3, adopted as the
# "Delegated defaults (2026-11-21)"). Trusted orgs get the plan limit, which is
# unlimited until billing exists (plan 01).
#
# Counters live in Rails.cache (Solid Cache in production). A cache that cannot
# count (the null store) allows the call: these are abuse brakes on top of the
# policy, not the policy itself.
module TenantLimits
  NEW = {
    servers: 2,
    invitations: 3,
    api_calls_per_minute: 30,
    concurrent_deploys: 1,
    ssh_attempts_per_hour: 20
  }.freeze

  # Proof-of-control dials (connections to a server that has NOT yet proved
  # ownership) are capped per org per hour (§ 5.4). Routine traffic to verified
  # servers — status syncs, metrics, deploys — is not counted: one server with
  # one app already makes ~40 connections an hour, and counting it would both
  # break deploys and flag every real tenant out of promotion.
  SSH_ATTEMPTS_PER_HOUR = 20

  module_function

  def limits_for(organization)
    organization&.new_tenant? ? NEW : nil
  end

  def limit(organization, key)
    limits_for(organization)&.fetch(key)
  end

  def server_limit_reached?(organization)
    cap = limit(organization, :servers)
    cap && organization.servers.count >= cap
  end

  def invitation_limit_reached?(organization)
    cap = limit(organization, :invitations)
    cap && organization.invitations.count >= cap
  end

  # Why this app may not start a deploy right now, or nil. Checked before the
  # preflight and NOT overridable with force.
  def deploy_refusal(app)
    org = app.organization
    return nil if org.nil?
    return "#{org.name} is suspended" if org.suspended?
    return app.control_plane_refusal if app.kamal? && app.control_plane_refusal

    if org.untrusted_network_origin? && app.server && !app.server.ownership_verified?
      return "#{app.server.name} has not proved ownership — finish the server verification step first"
    end

    cap = limit(org, :concurrent_deploys)
    if cap && Deployment.in_progress.where(app_id: org.apps.select(:id)).count >= cap
      return "new organizations run #{cap} deploy at a time — wait for the current one to finish"
    end

    nil
  end

  # Count one API/MCP call; false once a `new` org is over its minute bucket.
  # The first refusal in a window records an abuse flag (option B's clean record).
  def api_call!(organization, now: Time.current)
    cap = limit(organization, :api_calls_per_minute)
    return true unless cap

    count = bump("tenant-api:#{organization.id}:#{now.to_i / 60}", 2.minutes)
    return true if count.nil? || count <= cap

    organization.flag_abuse!(:api_throttle, "over #{cap} calls/minute") if count == cap + 1
    false
  end

  # Count one proof-of-control dial for an org the operator did not vet.
  def ssh_attempt!(organization, now: Time.current)
    return true unless organization&.untrusted_network_origin?

    count = bump("tenant-ssh:#{organization.id}:#{now.to_i / 3600}", 2.hours)
    return true if count.nil? || count <= SSH_ATTEMPTS_PER_HOUR

    organization.flag_abuse!(:ssh_attempts, "over #{SSH_ATTEMPTS_PER_HOUR} attempts/hour") if count == SSH_ATTEMPTS_PER_HOUR + 1
    false
  end

  def bump(key, ttl)
    store.increment(key, 1, expires_in: ttl)
  end

  def store
    @store || Rails.cache
  end

  # Tests swap in a real counting store (the test env uses :null_store).
  def store=(value)
    @store = value
  end
end
