# The ONE place an app's infrastructure form may change (ADR 0004).
#
# A form change is server, deploy method, edge, or database shape — the things
# that leave residue behind on the old shape. Ordinary config edits (name, port,
# notes, branch) are not form changes and don't come through here.
#
# Why a choke point at all: `infra_revision` is only worth having if it is
# always right. If a form can change without incrementing it, the revision lies
# — and a lying version is worse than no version, because residue detection then
# silently passes. So every path that changes one of these fields must call
# this, and `App` refuses the change otherwise.
#
#   AppFormChange.new(app, user: current_user).apply!(
#     deploy_method: "docker", reason: "moved off kamal"
#   )
class AppFormChange
  # Changing any of these changes the app's shape, and therefore what its old
  # shape left lying around on a box.
  #
  # These are the form-bearing columns on `apps`. The app's EDGE lives on its
  # server (`Server#edge_type`), so moving `server_id` is what changes an app's
  # edge — a server changing its own edge affects every app on it and needs its
  # own handling, which this deliberately does not pretend to cover.
  FORM_FIELDS = %w[server_id deploy_method database_mode database_placement].freeze

  class NotAFormChange < StandardError; end

  attr_reader :app, :revision

  # Apply a mixed attribute hash: ordinary config through a normal update, form
  # fields through the choke point. Every write path that accepts user input
  # should use this rather than deciding for itself — otherwise a perfectly valid
  # "move this app to another box" is refused by App's guard.
  #
  # Returns true on success; on failure the app carries the errors.
  def self.update(app, attributes, user: nil, reason: nil)
    attrs = attributes.to_h.transform_keys(&:to_s)
    form, ordinary = attrs.partition { |k, _| FORM_FIELDS.include?(k) }.map(&:to_h)

    app.transaction do
      raise ActiveRecord::Rollback unless ordinary.empty? || app.update(ordinary)
      next if form.empty?

      new(app, user: user).apply!(reason: reason, **form.symbolize_keys)
    end
    app.errors.empty?
  rescue ActiveRecord::RecordInvalid
    false
  end

  def initialize(app, user: nil)
    @app = app
    @user = user
  end

  # Apply the change and bump the revision, atomically. Raises
  # ActiveRecord::RecordInvalid if the app rejects the new values, so a failed
  # form change never leaves a revision behind.
  #
  # NB: this saves the app, so any unrelated attribute the caller has already
  # assigned in memory is persisted too. Pass a clean record.
  def apply!(reason: nil, **attributes)
    unknown = attributes.keys.map(&:to_s) - FORM_FIELDS
    if unknown.any?
      raise NotAFormChange, "#{unknown.join(', ')} are not form fields — use a normal update"
    end

    # Cheap pre-check WITHOUT dirtying the record — with_lock refuses one with
    # unpersisted changes, and re-applying identical values must not take a lock
    # or inflate the revision. The authoritative diff is recomputed under the
    # lock, against freshly-read values.
    return true if no_change?(attributes)

    changed = nil

    # Same lock protocol as EdgeDetector: both compute "current + 1", so without
    # a shared lock they can pick the same revision and one loses to the unique
    # index — silently dropping that history.
    app.with_lock do
      app.reload
      app.assign_attributes(attributes)

      # Re-checked under the lock: a concurrent writer may have already applied
      # exactly this change while we waited for it.
      changed = app.changes.slice(*FORM_FIELDS)
      next if changed.empty?

      app.infra_revision += 1
      app.save!(context: :form_change)

      @revision = app.infra_revisions.create!(
        revision: app.infra_revision,
        changes_made: changed,
        reason: reason,
        user: @user
      )
      log_change(changed)
    end
    true
  end

  private

  # True when every requested value already matches what is stored.
  def no_change?(attributes)
    attributes.all? { |key, value| app.public_send(key).to_s == value.to_s }
  end

  def log_change(changed)
    Rails.logger.info(
      "[form-change] app=#{app.id} (#{app.name}) -> revision #{app.infra_revision}: " \
      "#{changed.map { |f, (a, b)| "#{f} #{a.inspect}->#{b.inspect}" }.join(', ')}"
    )
  end
end
