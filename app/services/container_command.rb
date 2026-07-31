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

  # `docker <action>` against the app's container, resolved by LABEL for every
  # container form.
  #
  # A fixed name is no longer reliable for docker apps either: a zero-downtime
  # deploy runs the app as `app-<id>-r<rev>-<sha>`, so `docker stop
  # conductor-<slug>` matches nothing and "succeeds" against no container. Every
  # container Conductor starts now carries `service=<resource_key>` (ADR 0003),
  # so one label lookup covers docker, kamal, and anything renamed — with the
  # legacy fixed name kept as a fallback for containers deployed before this.
  def build(action)
    return native(action) if @app.native?

    # `ps -a` so a stopped container is still found (restart must reach it).
    %(cid=""; for s in #{candidates}; do cid=$(docker ps -aq -f "label=service=$s" | head -n1); [ -n "$cid" ] && break; done; ) +
      %(if [ -z "$cid" ]; then cid=$(docker ps -aq -f "name=^#{esc_name(@app.container_name)}$" | head -n1); fi; ) +
      %(if [ -n "$cid" ]; then docker #{action} "$cid"; else echo #{NO_CONTAINER}; fi)
  end

  private

  def native(action) = %(systemctl --user #{action} #{esc(@app.service_name)})

  # The stable resource key first (what Conductor labels with), then the Kamal
  # service variants, for containers Kamal itself created.
  # Deliberately BROAD (strict: false in App's terms): stopping or restarting
  # should reach a container left over from a previous form too — that is often
  # exactly what an operator is trying to do.
  def candidates
    ([ @app.resource_key ] + @app.kamal_service_candidates).uniq.map { |c| esc(c) }.join(" ")
  end

  def esc_name(name) = name.to_s.gsub(/[^a-zA-Z0-9_.-]/, "")

  def esc(str) = Shellwords.escape(str.to_s)
end
