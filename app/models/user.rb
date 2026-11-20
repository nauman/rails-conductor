class User < ApplicationRecord
  validates :email, presence: true, uniqueness: { case_sensitive: false }

  passwordless_with :email

  scope :admins, -> { where(admin: true) }

  class BootstrapRefused < StandardError; end

  # Sign-in is invite-only unless SIGNUP_MODE=open, and even then this method
  # never creates an account for a stranger: open sign-up goes through
  # SignupIntent, which creates the user only after the emailed link is clicked.
  #
  # The first admin:
  #   invite-only — the very first email on an empty database (self-host install);
  #   open        — only BOOTSTRAP_ADMIN_EMAIL, and only while no admin exists.
  # Unknown emails get nil (no auto-signup, no user enumeration).
  def self.fetch_resource_for_passwordless(email)
    normalized_email = email.to_s.downcase.strip

    existing = find_by(email: normalized_email)
    return existing if existing

    if bootstrap_candidate?(normalized_email)
      begin
        return bootstrap_admin!(normalized_email)
      rescue BootstrapRefused
        # Lost the race to another first request; fall through as an unknown email.
      end
    end

    accept_pending_invitation(normalized_email)
  end

  def self.bootstrap_candidate?(email)
    if SignupMode.open?
      SignupMode.bootstrap_admin_email == email && !admins.exists?
    else
      User.none? || (SignupMode.bootstrap_admin_email == email && !admins.exists?)
    end
  end

  # Create the platform admin, at most once. A transaction-scoped advisory lock
  # serialises concurrent first requests, so two of them cannot both see "no
  # admin yet" and both become admin. Re-checks under the lock and refuses when
  # someone else won.
  BOOTSTRAP_LOCK_KEY = 0x0C0D_0001

  #
  # `operator:` is true only for the rake task, run by someone with a shell on the
  # host. Every web path passes false, and then the seat is claimable only on an
  # empty database or by the configured BOOTSTRAP_ADMIN_EMAIL.
  def self.bootstrap_admin!(email, operator: false)
    normalized = email.to_s.downcase.strip
    transaction do
      connection.execute("SELECT pg_advisory_xact_lock(#{BOOTSTRAP_LOCK_KEY})")
      raise BootstrapRefused, "a platform admin already exists" if admins.exists?
      raise BootstrapRefused, "#{normalized} already has an account" if exists?(email: normalized)

      claimable = operator || User.none? || SignupMode.bootstrap_admin_email == normalized
      claimable = false if SignupMode.open? && !operator && SignupMode.bootstrap_admin_email != normalized
      raise BootstrapRefused, "set BOOTSTRAP_ADMIN_EMAIL to bootstrap an admin" unless claimable

      create!(email: normalized, admin: true, email_verified_at: Time.current).tap(&:ensure_personal_organization!)
    end
  end

  # An invited address has no User until the invite is accepted, so a normal
  # magic-link sign-in would fail with "we couldn't find a user". If a pending
  # invitation exists, create the user and accept it here so sign-in just works.
  # Still invite-gated: no invitation → nil (no self-signup, no user enumeration).
  def self.accept_pending_invitation(email)
    return nil unless Invitation.pending.exists?(email: email)

    create!(email: email).tap do |user|
      Invitation.pending.where(email: email).find_each { |invitation| invitation.accept!(user) }
    end
  end

  # Every user belongs to at least one organization. Creates a personal org
  # (owned by the user) if they don't yet belong to any.
  def ensure_personal_organization!
    return organizations.first if organizations.any?

    Organization.create_for(self, name: email.split("@").first)
  end

  has_many :memberships, dependent: :destroy
  has_many :organizations, through: :memberships

  # Deleting a user cascades their memberships, which would silently strip an
  # organization of its last owner. Refuse up front and name the org, so the
  # admin transfers ownership first rather than discovering an orphan later.
  #
  # `prepend: true` matters: `has_many dependent: :destroy` registers its own
  # before_destroy when the association is declared above, and callbacks run in
  # declaration order. Without prepend, Membership's guard aborts the cascade
  # first and this one never runs — destroy returns false with NO error, and the
  # caller shows a blank alert.
  before_destroy :ensure_not_the_last_owner_anywhere, prepend: true

  def orphaned_organizations
    organizations.select { |org| org.owner?(self) && org.memberships.owner.where.not(user_id: id).none? }
  end
  has_many :api_tokens, dependent: :destroy
  has_many :conversations, dependent: :destroy

  def admin? = admin

  def can?(action, record)
    permission_for(record).can?(action)
  end

  private

  def ensure_not_the_last_owner_anywhere
    orphaned = orphaned_organizations
    return if orphaned.empty?

    errors.add(:base, "is the last owner of #{orphaned.map(&:name).to_sentence} — transfer ownership first")
    throw :abort
  end

  def permission_for(record)
    case record
    when :conversation, Conversation
      ConversationPermission.new(user: self, record: record.is_a?(Conversation) ? record : nil)
    else
      raise ArgumentError, "No permission class for #{record.class}"
    end
  end
end
