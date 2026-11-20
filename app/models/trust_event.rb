# The audit trail of an organization's trust level: who (nil = the scheduled
# promotion job), when, from what, to what, and under which rule.
class TrustEvent < ApplicationRecord
  belongs_to :organization
  belongs_to :user, optional: true

  validates :from_level, :to_level, :reason, presence: true
end
