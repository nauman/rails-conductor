class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  # `editor` is appended as 2 deliberately. Slotting it between member and owner
  # would renumber every existing row and silently turn owners into editors.
  # Display order is a UI concern, not an enum concern.
  enum :role, { member: 0, owner: 1, editor: 2 }, default: :member

  validates :user_id, uniqueness: { scope: :organization_id }

  # The last-owner invariant lives here, not in a controller, so ordinary model
  # writes from anywhere — controllers, jobs, the console — cannot orphan an
  # organization.
  #
  # LIMIT: these are callbacks, so writes that skip them still bypass the
  # invariant — `update_column(s)`, `update_attribute`, `delete`, `delete_all`,
  # and raw SQL. Enforcing it against those needs a database constraint; tracked
  # as SB-002 in docs/dev/SECURITY-BACKLOG.md. Don't reach for those methods on
  # an owner row.
  validate :organization_keeps_an_owner, on: :update
  before_destroy :ensure_not_the_last_owner

  # Owner or editor — the two roles that may run infrastructure operations.
  def operator? = owner? || editor?

  private

  def organization_keeps_an_owner
    # Two ways an update can strip an org of its last owner: demote the row, or
    # move the row to a different organization. The second leaves `role`
    # untouched, so checking the role transition alone misses it.
    moved_away = organization_id_changed? && role == "owner"
    return unless role_changed?(from: "owner") || moved_away
    return if other_owners_exist?(organization_id_was)

    errors.add(:base, "can't leave #{Organization.find_by(id: organization_id_was)&.name || 'the organization'} without an owner")
  end

  def ensure_not_the_last_owner
    # A destroyed *organization* takes its memberships with it; that is not
    # orphaning, so let that cascade through. A destroyed *user* is a different
    # matter — it must not quietly strip an org of its last owner, so only the
    # Organization cascade is exempt.
    return if cascading_from_organization? || !owner?
    return if other_owners_exist?

    errors.add(:base, "can't remove the last owner of #{organization.name}")
    throw :abort
  end

  def cascading_from_organization?
    destroyed_by_association&.active_record == Organization
  end

  # Lock the org row so two concurrent demotions can't each observe the other
  # owner and both commit, leaving the organization with none. Defaults to the
  # current org; pass an id to check the one being moved away from.
  def other_owners_exist?(org_id = organization_id)
    org = org_id == organization_id ? organization : Organization.find_by(id: org_id)
    return true if org.nil?

    org.with_lock do
      org.memberships.where(role: :owner).where.not(id: id).exists?
    end
  end
end
