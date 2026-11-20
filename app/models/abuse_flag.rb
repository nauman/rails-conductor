# Something an org did that a clean record would not show: a throttle hit, an
# egress refusal, too many SSH attempts. Any flag inside the promotion window
# keeps a `new` org from being promoted (plan 02 § 5.3, option B).
class AbuseFlag < ApplicationRecord
  KINDS = %w[api_throttle ssh_attempts egress_refused limit_exceeded admin_note].freeze

  belongs_to :organization

  validates :kind, inclusion: { in: KINDS }
end
