# Drives an AppTransfer through the spec-26 Part 3 pipeline, one phase at a time,
# recording progress on the record so a crash is visible and the run is
# rollback-able. Each phase is check-then-act and delegates the actual mutation
# to an injected Collaborators object — the ENGINE (ordering, clone semantics,
# failure handling, progress) is what this class owns and tests.
#
# The default Collaborators refuse to touch real infrastructure (NotWired): the
# concrete wiring (deploy to target, DB replication, the KamalProxyAdapter for
# cross-edge cut-over, DNS repoint) is a later slice that must be verified
# end-to-end on a real box. Until then, a transfer plans (AppTransferPlan) and
# the engine is exercised with an injected collaborator, but never runs blind.
class AppTransferRunner
  HANDLERS = {
    "compute"  => :deploy_to_target,
    "database" => :replicate_database,
    "edge"     => :publish_on_target_edge,
    "cutover"  => :cut_over,
    "drain"    => :drain_source
  }.freeze

  def initialize(transfer, collaborators: nil)
    @transfer = transfer
    @collaborators = collaborators || Collaborators.new(transfer)
  end

  # Runs the planned phases in order. Returns true on success; on any phase
  # failure, records the failing phase + message and stops (no further phases).
  def run
    # Re-check the org boundary at execute time, not just when the plan was built:
    # a transfer record can sit between planning and running, and an app or server
    # can be moved between orgs in that window. Cheap, and the failure lands in the
    # normal failed-phase path below rather than mutating anything.
    AppTransferOrgBoundary.enforce!(app: @transfer.app, target_server: @transfer.target_server)

    @transfer.update!(status: "running", started_at: Time.current, error: nil)

    @transfer.planned_phases.each do |phase|
      @transfer.update!(phase: phase)
      @transfer.append_log("→ #{phase}")
      @collaborators.public_send(HANDLERS.fetch(phase))
      @transfer.append_log("✓ #{phase}")
    end

    # A completed transfer (not a clone) moves the app to its new home — the
    # control-plane record must follow the traffic, or subsequent deploys, status
    # syncs, and DB resolution keep operating against the drained source server.
    # Clone keeps the source live, so its app stays put.
    @transfer.app.update!(server: @transfer.target_server) if @transfer.transfer?

    @transfer.update!(status: "succeeded", finished_at: Time.current)
    true
  rescue StandardError => e
    @transfer.append_log("✗ #{@transfer.phase}: #{e.message}")
    # update_columns, not update!: recording a failure must never itself fail
    # validation. A run that dies *because* the record became invalid (an app or
    # server moved orgs mid-flight) would otherwise raise here and lose the reason
    # it stopped. Same reason append_log writes columns directly.
    @transfer.update_columns(status: "failed", error: "#{@transfer.phase}: #{e.message}",
                             finished_at: Time.current, updated_at: Time.current)
    false
  end

  # Mutating steps. Default is inert-and-loud so a transfer can't run against real
  # infrastructure before the wiring slice. Inject a real/fake implementation.
  class Collaborators
    class NotWired < StandardError; end

    def initialize(transfer)
      @transfer = transfer
    end

    def deploy_to_target       = not_wired!(:compute)
    def replicate_database     = not_wired!(:database)
    def publish_on_target_edge = not_wired!(:edge)
    def cut_over               = not_wired!(:cutover)
    def drain_source           = not_wired!(:drain)

    private

    def not_wired!(phase)
      raise NotWired, "#{phase} execution is not wired to real infrastructure yet"
    end
  end
end
