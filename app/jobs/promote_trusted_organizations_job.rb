# Option B, decided 2026-11-21: a `new` org becomes `trusted` 7 days after its
# card check if that window holds no abuse flags and it was never suspended.
# Each promotion is recorded as a TrustEvent naming the rule; a suspended org is
# never considered (only `new` orgs are).
class PromoteTrustedOrganizationsJob < ApplicationJob
  queue_as :ops

  RULE = "auto: 7 days after card check, clean record (plan 02 option B)".freeze

  def perform(now: Time.current)
    Organization.where(trust_level: "new").where(card_verified_at: ..(now - Organization::PROMOTION_PERIOD)).find_each do |org|
      next unless org.promotable?(now: now)

      org.change_trust!("trusted", reason: RULE)
    end
  end
end
