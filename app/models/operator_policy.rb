# Single source of truth for "who may do what" across every surface (web, API,
# MCP tools, jobs). Three org roles:
#
#   member — read only. No mutations, no secrets.
#   editor — a trusted operator: deploys, manages apps/servers/databases/env,
#            and sees app secrets. Cannot destroy, cannot run ad-hoc code,
#            cannot touch stored credentials, cannot manage members.
#   owner  — everything, including the four bands below.
#
# Two questions, one policy:
#
#   operator?(user, org)      — may they run ordinary infra ops? (owner OR editor)
#   can?(user, org, :destroy) — do they hold an owner-only capability?
#
# `operator?` keeps its original name and meaning-in-spirit so the ~20 existing
# call sites need no edit; every owner-only action asks `can?` instead.
#
# NB: "editor cannot execute arbitrary code" is a statement about *ad-hoc*
# execution — scripts, one-off runners, raw cron, seed toggles. An editor can
# still deploy, and deploying ships code by definition. Repointing an app at a
# different repository is therefore a trust change, not config, and is owner-only
# (:repository). See docs/scenarios/sc-009-editor-role.md.
module OperatorPolicy
  module_function

  # Capabilities reserved to org owners and platform admins.
  #
  #   :destroy        — deleting/retiring/transferring infrastructure
  #   :execute        — ad-hoc code: scripts, MCP runner, raw cron, seed runs
  #   :credentials    — stored provider credentials and SSH keys
  #   :manage_members — invitations, removals, role changes
  #   :repository     — repointing an app at a different source repository
  OWNER_ONLY = %i[destroy execute credentials manage_members repository].freeze

  # Capabilities an editor holds. Anything outside OWNER_ONLY + EDITOR is
  # unrecognized and denied to non-owners (see `can?`).
  EDITOR = %i[deploy configure read].freeze

  # Capabilities any member holds, gated only by the org's trust.
  #
  #   :chat — in-app chat spends operator-paid model calls (§ 5.5)
  MEMBER = %i[chat].freeze

  # Capabilities that run code on the CONTROL PLANE rather than the org's own
  # servers. Granted to operators of an org the operator vetted — never to a
  # self-signed-up org, at any trust level (Organization#control_plane_execution_allowed?).
  #
  #   :control_build — build on Conductor's host, or drive Kamal from it (Kamal
  #                    evaluates the repo's deploy.yml ERB, secrets and hooks there)
  CONTROL_PLANE = %i[control_build].freeze

  KNOWN = (OWNER_ONLY + EDITOR + MEMBER + CONTROL_PLANE).freeze

  # Trust gates, applied on top of the role bands (plan 02 § 5.3). A `new` org's
  # owner still holds every owner band EXCEPT these until promotion.
  TRUSTED_ONLY = %i[execute chat].freeze

  # May this user perform ordinary (non-owner-only) infrastructure operations?
  def operator?(user, organization)
    return false if user.nil?
    return true if user.admin?
    return false if organization&.suspended?

    !!organization&.operator?(user)
  end

  # Does this user hold `capability` in this organization? Unknown capabilities
  # fall back to the operator gate, so a new call site fails safe-ish (member is
  # still denied) rather than silently granting everyone.
  def can?(user, organization, capability)
    return false if user.nil?
    return true if user.admin?
    return false unless trust_permits?(organization, capability)

    # Fail CLOSED on anything unrecognized. A typo (`:credential`) or a string
    # instead of a symbol must not silently widen access to editors — an
    # authorization API whose default is "grant" is a bug waiting to be typed.
    return !!organization&.owner?(user) unless KNOWN.include?(capability)
    return !!organization&.owner?(user) if OWNER_ONLY.include?(capability)
    return organization.present? && organization.memberships.exists?(user: user) if MEMBER.include?(capability)

    operator?(user, organization)
  end

  # Does the org's trust level allow this capability at all, whoever asks?
  # Suspended allows nothing; control-plane work needs a vetted org; the
  # TRUSTED_ONLY bands need `trusted`. Unknown orgs (nil) are left to the role
  # check, which already denies them.
  def trust_permits?(organization, capability)
    return true if organization.nil?
    return false if organization.suspended?
    return organization.control_plane_execution_allowed? if CONTROL_PLANE.include?(capability)
    return organization.trusted? if TRUSTED_ONLY.include?(capability)

    true
  end
end
