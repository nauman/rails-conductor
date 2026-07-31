# One row per infrastructure SHAPE an app has been in (ADR 0004).
#
# Distinct from Deployment, which records code releases — many per day, all the
# same shape. This records the rarer, more dangerous event: the app changed
# form. Moving box, switching deploy method, changing edge, or converting the
# database each produce a revision, so "what shapes has this app been in, and
# which is it in now" stops living only in operators' heads.
class InfraRevision < ApplicationRecord
  belongs_to :app
  belongs_to :user, optional: true # nil when the change was system-initiated

  validates :revision, presence: true, uniqueness: { scope: :app_id }

  scope :recent, -> { order(revision: :desc) }

  # "server_id: 1 → 2, deploy_method: kamal → docker"
  def summary
    changes_made.map { |field, (before, after)| "#{field}: #{before.inspect} → #{after.inspect}" }.join(", ")
  end
end
