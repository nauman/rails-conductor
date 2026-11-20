class Invitation < ApplicationRecord
  belongs_to :organization
  belongs_to :invited_by, class_name: "User"

  has_secure_token

  # Must mirror Membership.roles exactly — accept! copies this straight across.
  enum :role, { member: 0, owner: 1, editor: 2 }, default: :member

  validates :email, presence: true
  validate :within_tenant_invitation_limit, on: :create
  validate :never_invites_a_platform_admin_into_an_unvetted_org, on: :create

  # Invitation mail goes out from the instance's sender, so a `new` org's cap is
  # also a cap on how much mail a stranger can make us send (plan 02 § 5.3).
  def within_tenant_invitation_limit
    return unless organization && TenantLimits.invitation_limit_reached?(organization)

    errors.add(:base, "New organizations can send up to #{TenantLimits.limit(organization, :invitations)} invitations")
  end

  # § 4.2 residual: a tenant inviting the platform admin hopes the admin clicks,
  # bringing the admin's global reach into a context the tenant controls. Refused
  # for every org the operator did not vet; the error is the generic one, so it
  # does not confirm which addresses are admins.
  def never_invites_a_platform_admin_into_an_unvetted_org
    return unless organization&.untrusted_network_origin?
    return unless User.admins.exists?(email: email.to_s.downcase.strip)

    errors.add(:email, "cannot be invited")
  end

  scope :pending, -> { where(accepted_at: nil) }

  def pending?
    accepted_at.nil?
  end

  # Add the user to the organization with the invited role (idempotent) and
  # mark the invitation accepted.
  def accept!(user)
    transaction do
      organization.memberships.find_or_create_by!(user: user) { |m| m.role = role }
      update!(accepted_at: Time.current)
    end
  end
end
