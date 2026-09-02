# Keeps Conductor's cached Cloudflare zone lists honest.
#
# The list is written by verify_cloudflare! and, until this existed, refreshed by
# nothing at all. Two credentials sat 34 days old while Conductor answered domain
# questions from them — reporting a real zone as absent and a deleted one as
# present, and sending readers to hunt a token-permissions problem that did not
# exist.
#
# The first fix only made staleness VISIBLE, which still required a human to notice
# a flag and act. That is a rule with no enforcement, and it is the same shape as
# the leaked browser sessions and the candidate containers that outlived their
# purpose: something whose correctness depended on someone remembering.
#
# Same stored-rollup pattern as ResidueCheckJob and ReleaseDriftCheckJob: the job
# pays the network cost out of band, the fast paths read what was stored.
class RefreshCloudflareZonesJob < ApplicationJob
  queue_as :default

  def perform(credential_id)
    credential = Credential.find_by(id: credential_id, provider: "cloudflare")
    return unless credential

    before = credential.zones_list.map { |z| z["name"] }.compact.sort
    error = credential.verify_cloudflare!

    if error
      # Never fatal, and never destructive: verify_cloudflare! leaves the cached
      # list untouched on failure, so a blip degrades to "stale" rather than to
      # "this account owns nothing".
      Rails.logger.warn "[CloudflareZones] #{credential.name}: refresh failed — #{error}"
      return
    end

    after = credential.reload.zones_list.map { |z| z["name"] }.compact.sort
    return if after == before

    Rails.logger.info(
      "[CloudflareZones] #{credential.name}: #{before.size} -> #{after.size} " \
      "(added: #{(after - before).join(', ').presence || 'none'}; " \
      "removed: #{(before - after).join(', ').presence || 'none'})"
    )
  end

  # Safe to run often — it only reads from Cloudflare and rewrites a cache.
  def self.sweep(organization = nil)
    scope = Credential.where(provider: "cloudflare")
    scope = scope.where(organization: organization) if organization
    scope.find_each { |credential| perform_later(credential.id) }
  end
end
