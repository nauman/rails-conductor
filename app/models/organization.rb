class Organization < ApplicationRecord
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :invitations, dependent: :destroy

  has_many :servers, dependent: :nullify
  has_many :apps, dependent: :nullify
  has_many :database_clusters, dependent: :destroy
  has_many :databases, dependent: :destroy
  has_many :cron_jobs, dependent: :destroy
  has_many :credentials, dependent: :nullify

  # GitHub API token (a fine-grained PAT or App installation token) for managing
  # deploy keys / webhooks on this org's repos.
  def github_token
    credentials.active.for_provider("github").first&.api_key
  end
  has_many :backups, dependent: :nullify
  has_many :ssh_keys, dependent: :nullify
  has_many :database_pulls, dependent: :nullify
  has_many :scripts, dependent: :destroy

  has_many :abuse_flags, dependent: :destroy
  has_many :trust_events, dependent: :destroy

  validates :name, presence: true

  # ---- Trust (plan 02 § 5.3) -------------------------------------------------
  #
  #   new       — a self-signed-up tenant inside its first period: limited powers.
  #   trusted   — every invited org, and a sign-up promoted after a clean period.
  #   suspended — an admin stopped it: tokens revoked, jobs halted, no operations.
  #
  # The column default is `trusted`, so every org that existed before open sign-up
  # keeps exactly the powers it had. Only the sign-up path writes `new`.
  TRUST_LEVELS = %w[new trusted suspended].freeze
  OPEN_SIGNUP = "open_signup".freeze
  PROMOTION_PERIOD = 7.days

  validates :trust_level, inclusion: { in: TRUST_LEVELS }

  def new_tenant? = trust_level == "new"
  def trusted? = trust_level == "trusted"
  def suspended? = trust_level == "suspended"
  def self_signed_up? = signup_source == OPEN_SIGNUP
  def card_verified? = card_verified_at.present?

  # Does anything this org asks for run ON the control plane — a build on the
  # Conductor host, or a Kamal process parsing the org's repo there (deploy.yml
  # is ERB, .kamal/secrets is shell, .kamal/hooks are executables)? Each of those
  # is code from the tenant running beside every other tenant's secrets.
  #
  # Only orgs the operator vetted get it: never a self-signed-up org, whatever
  # its trust level (§ 5.3 "operator org only"), and never a new/suspended one.
  def control_plane_execution_allowed?
    trusted? && !self_signed_up?
  end

  # Servers of an org the operator did not vet must prove control before any job
  # runs on them, and connect only to public addresses (§ 5.4).
  def untrusted_network_origin?
    self_signed_up? || !trusted?
  end

  # A new org cannot reach onboarding (or anything else) before the card check.
  def card_check_required?
    self_signed_up? && !card_verified?
  end

  # May this org act through a token or OAuth grant (API, MCP) at all? Same gate
  # as the web: not suspended, and past the card check.
  def tenant_access_refusal
    return "This organization is suspended." if suspended?
    return "Finish the card check in the browser before using the API or MCP." if card_check_required?

    nil
  end

  def change_trust!(to, reason:, by: nil)
    to = to.to_s
    raise ArgumentError, "unknown trust level #{to}" unless TRUST_LEVELS.include?(to)
    return if trust_level == to

    transaction do
      trust_events.create!(from_level: trust_level, to_level: to, reason: reason, user: by)
      update!(trust_level: to)
    end
  end

  # Kill switch for one tenant: stop it acting and revoke everything that lets
  # it act without a browser session. Scheduled work stops at the SSH boundary:
  # SshConnection refuses every server of a suspended org, so backups, metrics,
  # deploys and audits all fail closed without each job knowing about trust.
  def suspend!(by:, reason: "admin")
    transaction do
      change_trust!("suspended", reason: reason, by: by)
      ApiToken.where(organization_id: id).delete_all
      Doorkeeper::AccessToken.where(organization_id: id, revoked_at: nil).update_all(revoked_at: Time.current)
      Doorkeeper::AccessGrant.where(organization_id: id, revoked_at: nil).update_all(revoked_at: Time.current)
    end
  end

  # Option B (decision 2, 2026-11-21): promote a new org 7 days after its card
  # check if the window is clean — no abuse flags, no suspension.
  def promotable?(now: Time.current)
    return false unless new_tenant? && card_verified?
    return false if card_verified_at > now - PROMOTION_PERIOD
    return false if abuse_flags.where(created_at: card_verified_at..).exists?
    return false if trust_events.where(to_level: "suspended").exists?

    true
  end

  # One flag per kind per hour: a scheduled job hitting the same refusal every
  # two minutes is one event, not thirty rows.
  def flag_abuse!(kind, detail = nil)
    return if abuse_flags.where(kind: kind.to_s, created_at: 1.hour.ago..).exists?

    abuse_flags.create!(kind: kind.to_s, detail: detail.to_s.first(500))
  end

  # Create an org and make the given user its owner, atomically.
  #
  # The instance GitHub App grant (see GithubApp.serves?) comes with the org only
  # when a platform admin creates it — never from the sign-up mode or from params,
  # so no tenant can mint a granted org for itself, in any mode.
  def self.create_for(user, name:)
    transaction do
      org = create!(name: name, github_app_granted_at: (Time.current if user.admin?),
                    **trust_for_new_org(user))
      org.add_member(user, role: :owner)
      org
    end
  end

  # Who vets an org created from inside the app (the "new organization" page)?
  # In invite-only mode every user was invited, so the org is trusted, as before.
  # In open mode a non-admin's extra org is a sign-up in all but name: it starts
  # new, is marked self-signed-up, and passes its own card check — otherwise a
  # second org would be a way round every limit the first one has.
  def self.trust_for_new_org(user)
    return {} if user.admin? || !SignupMode.open?

    { trust_level: "new", signup_source: OPEN_SIGNUP }
  end

  def add_member(user, role: :member)
    memberships.create!(user: user, role: role)
  end

  def owner?(user)
    memberships.exists?(user: user, role: :owner)
  end

  # Owner or editor — may run ordinary infrastructure operations here. Asked
  # through OperatorPolicy rather than directly; see that class for the bands.
  def operator?(user)
    memberships.exists?(user: user, role: [ :owner, :editor ])
  end

  def role_for(user)
    memberships.find_by(user: user)&.role
  end

  def onboarded?
    onboarded_at.present?
  end
end
