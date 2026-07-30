require "shellwords"

class DecommissionRunner
  # Production binding for the teardown phases — turns each phase into a real
  # fleet action over SSH (containers, dedicated DB) plus a control-plane cleanup
  # (records). Thin by design, and SCOPED: it only ever touches THIS app's own
  # footprint on THIS box. Constructed deliberately by whatever triggers a retire,
  # so a run is always supervised. The SSH connection is injectable for tests.
  #
  # SAFETY: never a broad `docker prune`; never a `DROP DATABASE` against a shared
  # cluster. Only the app's service-labeled containers and its OWN dedicated DB
  # container/volume are removed.
  class FleetDeps
    def initialize(decommission, ssh: nil)
      @d = decommission
      @app = decommission.app
      @server = decommission.server
      @ssh = ssh
    end

    def ssh
      @ssh ||= SshConnection.new(@server)
    end

    # Stop + remove the app's own containers, scoped by the kamal service label —
    # NEVER a broad prune. Runs per service candidate (an adopted app's label may
    # differ from its slug). `|| true` so an already-absent container is a no-op.
    def remove_containers
      @app.kamal_service_candidates.each do |svc|
        filter = "label=service=#{svc}"
        run!(%(cids=$(docker ps -aq --filter #{Shellwords.escape(filter)}); ) +
             %([ -n "$cids" ] && docker rm -f $cids || true),
             step: "remove containers (#{filter})")
      end
    end

    # Remove the app's OWN dedicated DB container + volume. No-op (and logged) for
    # a shared-cluster app — a shared cluster's DB is NEVER auto-dropped.
    def remove_dedicated_db
      unless @app.dedicated_db?
        @d.append_log("  · dedicated_db: #{@app.slug} is shared-cluster — leaving the shared DB untouched")
        return
      end

      run!(%(docker rm -f #{Shellwords.escape(@app.dedicated_db_container_name)} 2>/dev/null || true),
           step: "remove dedicated DB container #{@app.dedicated_db_container_name}")
      run!(%(docker volume rm #{Shellwords.escape(@app.dedicated_db_volume)} 2>/dev/null || true),
           step: "remove dedicated DB volume #{@app.dedicated_db_volume}")
    end

    # Destroy the stale Conductor Database records for THIS box only — never the
    # app's records on its current live server. Shared-cluster records are removed
    # from the control plane too (the DB itself on the cluster is left for a human).
    def clean_records
      stale = @app.databases.joins(:database_cluster)
                  .where(database_clusters: { server_id: @server.id })
      stale.find_each do |db|
        @d.append_log("  · records: destroying Database ##{db.id} (#{db.name}) on #{db.database_cluster.container_name}")
        db.destroy!
      end
    end

    private

    def run!(command, step:)
      @d.append_log("  · #{step}")
      result = ssh.execute_with_status(command)
      raise "#{step} failed: #{ssh.error || result[:stderr]}" unless result[:success]
    end
  end
end
