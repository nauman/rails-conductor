# The canon: Conductor's LEXICON for what shape an app is, and which ritual applies.
#
# Rituals themselves live in jazari — recipes, checklists, runs, revision guards.
# This carries no steps, deliberately: a vocabulary that starts holding procedures
# becomes a second task system, and jazari already is the first. What it owns is the
# naming, because a lexicon is not a procedure.
#
# It exists because an app's shape was only ever inferable from prose. `deploy_method`
# conflates two independent facts — the ARTIFACT contract (how the image is built and
# addressed) and the DRIVER (who performs the roll) — which is why InventList cannot
# record the truth: setting it to "docker" flips a residue heuristic on and
# manufactures false findings against a healthy app. Splitting the axes lets the
# record be true without changing any heuristic's meaning.
#
# Composition, not duplication: #target_for hands jazari a subject plus a recipe id.
# jazari resolves the runbook, owns the checklist and the run, and guards revisions.
class FleetCanon
  # The independent axes. Closed on purpose — an open vocabulary is how "kamal" came
  # to mean three different things at once.
  AXES = %i[artifact driver edge].freeze

  # How the image is built and addressed. This is the artifact contract, and it does
  # NOT say who deploys it.
  ARTIFACTS = %w[kamal docker native].freeze

  # Who performs the roll. `external` means a path Conductor does not drive — a repo
  # script, CI, or a human — and it is a different fact from the artifact.
  DRIVERS = %w[conductor external].freeze

  # What routes traffic to the container. Independent of both above: a kamal app can
  # sit behind host Caddy, and that is the sanctioned Caddy-mode shape.
  EDGES = %w[kamal_proxy caddy none].freeze

  # shape → the jazari recipe that governs it. Pointers only; jazari holds the steps.
  RECIPES = {
    external_driver: "external-driver-app",
    native: "native-app",
    caddy_mode: "caddy-mode-app",
    kamal_proxy: "kamal-proxy-app",
    plain_docker: "plain-docker-app"
  }.freeze

  # A hold whose reason names another deploy path is evidence of an external driver.
  # Reading it from the hold rather than a free-text note keeps the signal where an
  # operator already writes it.
  EXTERNAL_PATH_HINT = /bin\/deploy|deploy-ssdnode|do not.*kamal|NOT via .*kamal|via CI/i

  class << self
    def shape_for(app)
      artifact = app.deploy_method.to_s
      edge = app.server&.edge_type.presence || "none"
      driver = driver_for(app)

      { artifact: artifact, driver: driver, edge: edge,
        recipe_id: recipe_id_for(artifact: artifact, driver: driver, edge: edge) }
    end

    # The jazari target for this subject: the record, a stable public reference, and
    # the recipe pointer. No steps cross this boundary.
    def target_for(app)
      Jazari::RecordTarget.new(
        runbookable: app,
        public_reference: "app-#{app.id}",
        recipe_id: shape_for(app)[:recipe_id]
      )
    end

    private

    def driver_for(app)
      return "external" if app.deploy_hold? && app.deploy_hold_reason.to_s.match?(EXTERNAL_PATH_HINT)

      "conductor"
    end

    # Order matters: who drives the roll outranks how it is built, because an
    # externally-driven app must not be handed a ritual that tells Conductor to deploy.
    def recipe_id_for(artifact:, driver:, edge:)
      return RECIPES[:external_driver] if driver == "external"
      return RECIPES[:native] if artifact == "native"
      return RECIPES[:caddy_mode] if edge == "caddy"
      return RECIPES[:kamal_proxy] if artifact == "kamal"

      RECIPES[:plain_docker]
    end
  end
end
