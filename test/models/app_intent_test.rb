require "test_helper"

# An app's INTENT — what you've decided about it — as distinct from its deploy state.
#
# The fleet flattened three different situations into one label ("not deployed here") and
# would nag about all of them: an app that genuinely should be adopted, two that are running
# and awaiting migration into calm.page themes, and two placeholders. Nagging about a
# decision you already made is the "scolds without fixing" failure a checklist must never
# become.
class AppIntentTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "intent@example.com")
    @org = Organization.create_for(user, name: "Acme")
  end

  def app(intent: nil, slug: "a-#{SecureRandom.hex(3)}")
    @org.apps.create!(name: slug.titleize, slug: slug, **(intent ? { intent: intent } : {}))
  end

  test "an app is managed unless you say otherwise" do
    assert_equal "managed", app.intent, "the default must be the one that gets looked after"
  end

  test "intent is validated" do
    a = app
    a.intent = "whatever"
    refute a.valid?
    assert_match(/intent/i, a.errors.full_messages.join.downcase)
  end

  test "only managed and unmanaged apps are ever nagged" do
    managed = app(intent: "managed")
    unmanaged = app(intent: "unmanaged")
    app(intent: "pending_migration")
    app(intent: "placeholder")

    assert_equal [ managed, unmanaged ].map(&:slug).sort, App.naggable.pluck(:slug).sort
  end

  test "a decision you already made is never chased" do
    refute app(intent: "pending_migration").naggable?, "running until calm.page serves it"
    refute app(intent: "placeholder").naggable?, "you already said it's a placeholder"
    assert app(intent: "unmanaged").naggable?, "an unadopted app IS the gap"
    assert app(intent: "managed").naggable?
  end

  # needs_attention? means "something is wrong RIGHT NOW" and drives incidents. A parked app
  # can't qualify, even when its container is exited — that's the state you chose.
  test "a parked app raises no incident even with a dead container" do
    parked = app(intent: "placeholder")
    parked.update!(status: "running", container_status: "exited")
    refute parked.needs_attention?

    live = app(intent: "managed")
    live.update!(status: "running", container_status: "exited")
    assert live.needs_attention?, "a managed app with a dead container is a real incident"
  end

  # The label is the whole point: "not deployed here" on an app you deliberately park reads
  # as an accusation. Each intent says something different.
  test "each intent reads differently in the fleet" do
    assert_equal "pending migration", app(intent: "pending_migration").intent_label
    assert_equal "placeholder", app(intent: "placeholder").intent_label
    assert_equal "not adopted", app(intent: "unmanaged").intent_label
    assert_nil app(intent: "managed").intent_label, "managed is the norm — no badge"
  end

  # Never-deployed is a LABEL, not an incident — five apps are in that state and turning
  # each into a critical would bury the two that are actually broken.
  test "never deployed is naggable but not an incident" do
    a = app(intent: "managed")
    assert_nil a.deploy_health
    assert a.naggable?, "adoption prompts and checklists should reach it"
    refute a.needs_attention?, "but it is not an alarm"
  end

  test "pending_migration carries where it is going" do
    a = app(intent: "pending_migration", slug: "intellectaco")
    a.update!(intent_note: "becomes a calm.page Liquid theme")

    assert_equal "becomes a calm.page Liquid theme", a.intent_note
  end
end
