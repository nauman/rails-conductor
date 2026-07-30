# The recurring fleet decommission gotchas — the ones we keep re-learning box by
# box. DecommissionPlan checks these EVERY time (so the same surprise isn't
# rediscovered), and DecommissionRunner folds the ones that fired into the app's
# runbook on completion. Keep this list small and load-bearing: one entry per
# real, recurring class of surprise.
module DecommissionGotchas
  GOTCHAS = [
    {
      code: "native_vs_docker_port",
      severity: "warning",
      note: "Port ownership is not always docker: a NATIVE puma/ruby process can hold the app's port " \
            "instead of a docker-proxy. Check `ss -tlnp` before assuming `docker rm` frees the port."
    },
    {
      code: "docker_native_duplication",
      severity: "critical",
      note: "A native puma AND a docker container can BOTH claim the same service — remove both, and " \
            "stop the native systemd --user unit, or the port stays bound after the container is gone."
    },
    {
      code: "stale_idle_container",
      severity: "warning",
      note: "An 'idle' exited/created container is still present (and can still hold a published port). " \
            "Inspect with `docker ps -a`, not just `docker ps`, before calling the box clean."
    },
    {
      code: "retire_before_move",
      severity: "critical",
      note: "Retire only AFTER the app's home (server_id) has moved off this box. Retiring the live home " \
            "orphans the app — move it first (conductor_app action=transfer)."
    },
    {
      code: "shared_cluster_db",
      severity: "warning",
      note: "Never auto-DROP a shared-cluster database — only the app's OWN dedicated DB container/volume " \
            "is removed. A shared-cluster copy is left for a human to clean up deliberately."
    }
  ].freeze

  def self.find(code)
    GOTCHAS.find { |g| g[:code] == code }
  end

  # The one-line note for a gotcha code, used to seed runbook learnings.
  def self.note(code)
    find(code)&.fetch(:note)
  end
end
