# Finds organizations left with no owner (SB-002).
#
# Membership enforces "an org always has an owner" with Rails callbacks, which
# `update_column`, `delete_all` and raw SQL bypass. The real fix is a deferred
# constraint trigger, but that requires adopting structure.sql — a schema
# management change affecting every future migration in a repo several agents
# share. That is scheduled work, not something to slip in.
#
# This is the proportionate interim: it cannot PREVENT the state, but it removes
# the outcome that actually hurts — an organization silently unmanageable
# because member management requires an owner, discovered only when someone
# tries to use it.
#
# Detection, deliberately. It reports and never repairs: choosing who becomes an
# owner is a governance decision, and a job that silently promotes someone is
# worse than the problem it solves.
class OwnerlessOrganizationCheckJob < ApplicationJob
  queue_as :ops

  def perform
    orphaned = self.class.ownerless

    if orphaned.empty?
      Rails.logger.debug { "[OwnerlessOrgCheck] all organizations have an owner" }
      return []
    end

    orphaned.each do |org|
      Rails.logger.error(
        "[OwnerlessOrgCheck] organization #{org.id} (#{org.name}) has NO owner — " \
        "member management is impossible through the UI until one is restored. " \
        "Recover: Organization.find(#{org.id}).memberships.find_by(user_id: <id>).update!(role: :owner) " \
        "from a console, or promote via a platform admin."
      )
    end

    orphaned
  end

  # Organizations with at least one membership but none of role owner.
  #
  # An org with NO memberships at all is excluded: that is a different (and
  # currently harmless) state — nobody is locked out of anything, because nobody
  # is in it.
  def self.ownerless
    Organization
      .where(id: Membership.select(:organization_id))
      .where.not(id: Membership.owner.select(:organization_id))
  end
end
