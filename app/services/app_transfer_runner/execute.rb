class AppTransferRunner
  # Real collaborators for AppTransferRunner: thin orchestration that composes the
  # transfer primitives through a `deps` binding (FleetDeps in production, a fake
  # in tests). Plugs into the runner as `collaborators:`. The runner's DEFAULT
  # collaborators stay NotWired, so a transfer only executes when a caller
  # explicitly wires this up with an object-store credential — never by accident.
  class Execute
    def initialize(transfer, deps:)
      @t = transfer
      @app = transfer.app
      @deps = deps
      @source = transfer.source_server || @app.server
    end

    # database: provision the (empty) target <app>-db, then replicate source→target
    # BEFORE the deploy so the app boots against populated data (not an empty DB it
    # would migrate, only to have the restore then collide with that schema).
    def replicate_database
      source_url = @app.dedicated_database(server: @source)&.database_url
      target_db = @deps.provision_target_db!
      @deps.replicate!(source_url: source_url, target_url: target_db.database_url) if source_url.present?
    end

    # compute: deploy to the target — DATABASE_URL resolves to the target DB
    # (server-scoped), while the source keeps pointing at its own.
    def deploy_to_target
      @deps.deploy_to_target!
    end

    # edge: publish the domain on the target's edge (no-op if the app has no domain).
    def publish_on_target_edge
      @deps.publish_edge!(domain: @app.domain) if @app.domain.present?
    end

    # cutover: repoint DNS to the target box (no-op without a domain).
    def cut_over
      @deps.repoint_dns!(domain: @app.domain, ip: @t.target_server.ip_address) if @app.domain.present?
    end

    # drain: stop the app on the source. Skipped for a clone (planned_phases drops
    # this phase), which leaves the source live.
    def drain_source
      @deps.stop_source!
    end
  end
end
