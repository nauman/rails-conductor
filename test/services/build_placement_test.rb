require "test_helper"

class BuildPlacementTest < ActiveSupport::TestCase
  # A stand-in for the budget check. It answers the same question the real one asks
  # GitHub, so the ladder can be tested without a network or a token.
  class FakeBudget
    def initialize(status) = @status = status
    def status = @status
  end

  setup do
    user = User.create!(email: "bp@example.com")
    @org = Organization.create_for(user, name: "BP")
    @serving = @org.servers.create!(name: "serving-box", status: "online", ip_address: "203.0.113.1")
    @app = @org.apps.create!(name: "App", slug: "bp-app", server: @serving,
                             deploy_method: "kamal", repository_url: "https://github.com/acme/app.git")
  end

  def placement(budget) = BuildPlacement.new(@app, ci: FakeBudget.new(budget))

  test "CI wins when it has minutes — free, and nowhere near production" do
    choice = placement({ blocked_by: nil }).choose

    assert_equal :ci, choice.venue
    assert_equal "github-actions", choice.target
  end

  test "an exhausted quota falls through to a server opted in for builds" do
    builder = @org.servers.create!(name: "quiet-box", status: "online", ip_address: "203.0.113.2", build_role: true)

    choice = placement({ blocked_by: :quota_exhausted }).choose

    assert_equal :builder, choice.venue
    assert_equal builder.name, choice.target
  end

  # The whole point of the flag: every box in this fleet serves something, so a
  # machine is enlisted by an act, never by being available.
  test "a server is never used for builds unless it opted in" do
    @org.servers.create!(name: "busy-box", status: "online", ip_address: "203.0.113.3", build_role: false)

    choice = placement({ blocked_by: :quota_exhausted }).choose

    assert_equal :control, choice.venue, "an un-opted-in server must not be enlisted"
  end

  test "prefers the quietest opted-in builder" do
    busy = @org.servers.create!(name: "builder-busy", status: "online", ip_address: "203.0.113.4", build_role: true)
    quiet = @org.servers.create!(name: "builder-quiet", status: "online", ip_address: "203.0.113.5", build_role: true)
    @org.apps.create!(name: "Other", slug: "other", server: busy, deploy_method: "kamal")

    assert_equal quiet.name, placement({ blocked_by: :quota_exhausted }).choose.target
  end

  test "an offline builder is skipped rather than chosen and failed into" do
    @org.servers.create!(name: "down-box", status: "offline", ip_address: "203.0.113.6", build_role: true)

    assert_equal :control, placement({ blocked_by: :quota_exhausted }).choose.venue
  end

  test "the ladder explains every rung, not just the winner" do
    ladder = placement({ blocked_by: :quota_exhausted }).ladder

    ci = ladder.find { |c| c.venue == :ci }
    assert_equal :quota_exhausted, ci.reason
    assert_includes BuildPlacement::PLACEMENT_FAILURES, ci.reason
    assert_equal 3, ladder.size, "an operator asking why deserves the whole ladder"
  end

  # The distinction this class exists to hold: a venue is abandoned when it cannot
  # RUN the build, never because the build failed. A compile error must not be
  # rebuilt somewhere else — that spends the resource we are protecting to reach the
  # same red, twice as slowly.
  test "build failures are not placement failures" do
    %i[compile_error test_failure bad_dockerfile].each do |not_a_venue_problem|
      refute_includes BuildPlacement::PLACEMENT_FAILURES, not_a_venue_problem
    end
  end
end
