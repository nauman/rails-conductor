# Ownership record binding an R2 bucket (on a specific Cloudflare account) to the
# org that first used it through Conductor. R2 audit fix (finding 1): Cloudflare
# authorizes at the ACCOUNT level, so resolving an app's zone proves the account,
# not that the bucket belongs to the acting org. This record makes ownership
# explicit — a bucket claimed by org A can never be mutated by org B, even when
# both sit behind one Cloudflare account.
class StorageBucket < ApplicationRecord
  # Raised when a bucket is already claimed by a different organization.
  class CrossOrg < StandardError; end

  belongs_to :organization
  belongs_to :app, optional: true

  validates :name, :cloudflare_account_id, presence: true
  validates :name, uniqueness: { scope: :cloudflare_account_id }

  # Claim (account_id, name) for `organization` on first use; return the record.
  # Raise CrossOrg if it's already another org's bucket. Backfills the app link
  # when it was first claimed without one.
  def self.claim!(organization:, account_id:, name:, app: nil)
    existing = find_by(cloudflare_account_id: account_id, name: name)
    return create!(organization: organization, app: app, name: name, cloudflare_account_id: account_id) unless existing

    if existing.organization_id != organization.id
      raise CrossOrg, "bucket #{name} on this Cloudflare account belongs to another organization"
    end

    existing.update!(app: app) if app && existing.app_id.nil?
    existing
  end
end
