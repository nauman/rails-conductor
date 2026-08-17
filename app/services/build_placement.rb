# Where should this app's image be built?
#
# Conductor has never actually chosen. Kamal reads `builder.remote` from the app's
# own repo and the docker path builds over SSH on the target, so "where" was decided
# by files this side does not own — and the answer turned out to be "on a machine
# serving production" for every app in the fleet. This makes the choice explicit,
# ordered, and cheap first.
#
# The order is deliberate and the reasons are not interchangeable:
#
#   1. CI      — free, and builds nowhere near production. Chosen when the repo has
#                a build workflow and the account still has minutes.
#   2. builder — a server explicitly opted in with build_role. Costs nothing extra
#                if it is a box you already run for something quiet.
#   3. control — Conductor's own container, i.e. a box serving live apps. Last
#                resort, because it is the case this class exists to stop being the
#                default.
#
# THE DISTINCTION THAT MATTERS: a placement is abandoned only when the venue cannot
# run the build — no minutes, no runner, no workflow, host unreachable. It is NEVER
# abandoned because the build itself failed. Falling back on a compile error would
# rebuild the same broken commit somewhere else, double the wait, and spend the
# resource we are protecting to reach the same red. "Can't run here" and "the thing
# being run is broken" are different facts; conflating them is how a fallback turns
# into a machine for wasting time.
class BuildPlacement
  Choice = Struct.new(:venue, :target, :reason, keyword_init: true) do
    def ci? = venue == :ci
    def to_s = "#{venue}#{" (#{target})" if target}"
  end

  # Reasons a VENUE cannot take the work. Anything not on this list — a failing
  # test, a bad Dockerfile, a missing gem — is the build's own failure and stops
  # the deploy where it stands.
  PLACEMENT_FAILURES = %i[quota_exhausted no_runner no_workflow unreachable not_configured
                          unsupported_deploy_method].freeze

  def initialize(app, ci: nil)
    @app = app
    @ci = ci || GithubActionsBudget.new(app)
  end

  # The ordered venues, each with why it was or was not taken. Returns every
  # candidate rather than just the winner: an operator asking "why is this building
  # there?" deserves the whole ladder, not the last rung.
  def ladder
    [ ci_choice, builder_choice, control_choice ].compact
  end

  def choose = ladder.find { |c| c.reason.nil? } || control_choice

  private

  def ci_choice
    # HONEST LIMIT: the CI and registry-reuse path is wired into KamalDeployer only.
    # A docker-method app builds via AppDeployer, which runs `docker build` over SSH on
    # the target — so offering it CI here would describe coverage this does not have.
    # Native apps have no image at all. Say unsupported rather than let the ladder
    # imply a venue that cannot be reached.
    return Choice.new(venue: :ci, reason: :unsupported_deploy_method) unless @app.deploy_method.to_s == "kamal"

    unless @app.repository_url.present?
      return Choice.new(venue: :ci, reason: :not_configured)
    end

    budget = @ci.status
    return Choice.new(venue: :ci, target: "github-actions", reason: budget[:blocked_by]) if budget[:blocked_by]

    Choice.new(venue: :ci, target: "github-actions")
  end

  def builder_choice
    server = builder_server
    return Choice.new(venue: :builder, reason: :not_configured) if server.nil?
    return Choice.new(venue: :builder, target: server.name, reason: :unreachable) unless server.status == "online"

    Choice.new(venue: :builder, target: server.name)
  end

  # A box opted in with build_role, preferring one that serves nothing. Ordering by
  # app count means a quiet machine wins over a busy one without anyone tuning it.
  def builder_server
    Server.where(build_role: true, organization_id: @app.organization_id)
          .left_joins(:apps).group(:id).order(Arel.sql("COUNT(apps.id) ASC")).first
  end

  def control_choice
    Choice.new(venue: :control, target: "conductor control machine")
  end
end
