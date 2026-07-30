class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :organization

  # `editor` is appended as 2 deliberately. Slotting it between member and owner
  # would renumber every existing row and silently turn owners into editors.
  # Display order is a UI concern, not an enum concern.
  enum :role, { member: 0, owner: 1, editor: 2 }, default: :member

  validates :user_id, uniqueness: { scope: :organization_id }

  # The last-owner invariant lives here, not in a controller, so console edits,
  # background jobs, and cascading user deletion cannot orphan an organization.
  validate :organization_keeps_an_owner, on: :update
  before_destroy :ensure_not_the_last_owner

  # Owner or editor — the two roles that may run infrastructure operations.
  def operator? = owner? || editor?

  private

  def organization_keeps_an_owner
    return unless role_changed?(from: "owner")
    return if other_owners_exist?

    errors.add(:role, "can't be changed — an organization must always have an owner")
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
  # owner and both commit, leaving the organization with none.
  def other_owners_exist?
    organization.with_lock do
      organization.memberships.where(role: :owner).where.not(id: id).exists?
    end
  end
end
