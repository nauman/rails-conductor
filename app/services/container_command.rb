require "shellwords"

# Builds the docker command that acts on an app's LIVE container, for whatever
# form that app is in.
#
# A plain docker app runs under a fixed name (`conductor-<slug>`). A Kamal app
# does NOT — its container is `<service>-<role>-<version>`, so a fixed name never
# matches and the command silently acts on nothing. Kamal containers are located
# by their `service` label, the same lookup logs and status sync use.
#
# This existed only inside RestartAppJob, so the UI's Stop button used a fixed
# name for every app and reported "App stopped." for Kamal apps while the
# container kept running. One implementation, shared by both.
class ContainerCommand
  # Emitted by the shell snippet when no container matches, so the caller can
  # tell "nothing to act on" apart from "the action failed".
  NO_CONTAINER = "NO_CONTAINER".freeze

  def self.stop(app)    = new(app).build("stop")
  def self.restart(app) = new(app).build("restart")

  def initialize(app)
    @app = app
  end

  # `docker <action>` against the app's container, resolved by form.
  def build(action)
    return native(action) if @app.native?
    return %(docker #{action} #{esc(@app.container_name)}) unless @app.kamal?

    # `ps -a` so a stopped container is still found (restart must reach it).
    %(cid=""; for s in #{candidates}; do cid=$(docker ps -aq -f "label=service=$s" | head -n1); [ -n "$cid" ] && break; done; ) +
      %(if [ -n "$cid" ]; then docker #{action} "$cid"; else echo #{NO_CONTAINER}; fi)
  end

  private

  def native(action) = %(systemctl --user #{action} #{esc(@app.service_name)})

  def candidates = @app.kamal_service_candidates.map { |c| esc(c) }.join(" ")

  def esc(str) = Shellwords.escape(str.to_s)
end
