require "test_helper"

# Spec 07, slice 1 — a deploy failure has to stop shouting once a later deploy fixes it.
#
# The fleet read "11 failures this week" when 8 had already been superseded and only 3 apps
# were actually broken. Counting history instead of current state trains an operator to
# ignore the badge, which is worse than not having one.
class AppDeployHealthTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "health@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @app = @org.apps.create!(name: "Appone", slug: "appone")
  end

  def deploy!(status, at: Time.current, **attrs)
    @app.deployments.create!(user: @user, status: status, created_at: at, **attrs)
  end

  test "an app with no deployments has no deploy health to report" do
    assert_nil @app.deploy_health
    refute @app.deploy_failing?
  end

  test "a failure that a later deploy fixed is not a current problem" do
    deploy!("failed", at: 2.hours.ago)
    deploy!("succeeded", at: 1.hour.ago)

    assert_equal "succeeded", @app.deploy_health
    refute @app.deploy_failing?, "the failure was superseded — it belongs to history"
  end

  test "the latest deploy failing is a current problem" do
    deploy!("succeeded", at: 2.hours.ago)
    deploy!("failed", at: 1.hour.ago)

    assert_equal "failed", @app.deploy_health
    assert @app.deploy_failing?
  end

  test "an in-flight deploy is neither failing nor healthy" do
    deploy!("failed", at: 2.hours.ago)
    deploy!("deploying", at: 1.minute.ago)

    assert_equal "deploying", @app.deploy_health
    refute @app.deploy_failing?, "a running deploy is not yet a failure"
  end

  test "a blocked deploy is a current problem — it never ran" do
    deploy!("blocked", at: 1.hour.ago)

    assert_equal "blocked", @app.deploy_health
    assert @app.deploy_failing?
  end

  test "failing_now counts apps, not failures" do
    # One app that failed three times and recovered — zero problems.
    3.times { |i| deploy!("failed", at: (5 - i).hours.ago) }
    deploy!("succeeded", at: 1.hour.ago)

    broken = @org.apps.create!(name: "Broken", slug: "broken")
    broken.deployments.create!(user: @user, status: "succeeded", created_at: 3.hours.ago)
    broken.deployments.create!(user: @user, status: "failed", created_at: 1.hour.ago)

    assert_equal [ broken ], App.failing_now.to_a
    assert_equal 1, App.failing_now.count, "4 failed deploys, 1 broken app"
  end

  test "failing_now ignores apps that never deployed" do
    @org.apps.create!(name: "Never", slug: "never")
    assert_empty App.failing_now.to_a
  end

  # Not every red deploy is the app's fault. Two of this week's failures were Conductor's
  # own bugs (a shared buildx builder, a stale SSH identity), and showing them the same as
  # a broken migration sends people to debug the wrong thing.
  test "a deployment records what kind of thing went wrong" do
    d = deploy!("failed", cause_class: "infrastructure")

    assert_equal "infrastructure", d.cause_class
    assert d.infrastructure_failure?
    refute d.app_code_failure?
  end

  test "cause_class is optional and validated when present" do
    assert deploy!("failed").valid?, "old rows have no cause"

    d = @app.deployments.build(user: @user, status: "failed", cause_class: "gremlins")
    refute d.valid?
    assert_match(/cause/i, d.errors.full_messages.join)
  end

  test "the app reports why it is failing, when it knows" do
    deploy!("failed", cause_class: "infrastructure")

    assert @app.deploy_failing?
    assert_equal "infrastructure", @app.deploy_failure_cause
  end

  # The classifier only fires on signatures we have actually seen fail in production,
  # because calling an app-code failure "infrastructure" (or the reverse) sends someone
  # to debug the wrong system.
  test "a failure that looks like infrastructure is labelled as such" do
    d = deploy!("deploying")
    d.fail!("kamal deploy failed: no such identity: /home/rails/.ssh/conductor_x")

    assert_equal "infrastructure", d.reload.cause_class
  end

  test "an unrecognised failure is left unclassified rather than blamed on the app" do
    d = deploy!("deploying")
    d.fail!("migration failed: PG::UndefinedColumn")

    assert_nil d.reload.cause_class, "guessing blame is worse than saying nothing"
  end

  test "an explicit cause wins over the guess" do
    d = deploy!("deploying")
    d.fail!("anything at all", cause: "preflight")

    assert_equal "preflight", d.reload.cause_class
  end
end
