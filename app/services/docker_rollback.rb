require "shellwords"

# Boots a previously-shipped docker release again (ADR 0003).
#
# This is possible only because the deploy path now tags images by commit SHA
# and retains them. Previously every build was `:latest` and the old image was
# pruned seconds later, so there was no artifact to return to — which is why
# docker apps "didn't support rollback". Nothing about it was hard; the release
# was simply being thrown away.
#
# No rebuild: the image already exists on the host, so this is stop → run the
# older tag → repoint the edge. That also makes it fast, which matters when
# you're rolling back because production is broken.
class DockerRollback
  attr_reader :app, :deployment, :error

  def initialize(app, deployment, ssh: nil)
    @app = app
    @deployment = deployment
    @ssh = ssh || SshConnection.new(app.server)
  end

  # `version` is the immutable image tag recorded on the target deployment.
  def rollback!(version)
    deployment.start!
    log "Rolling back #{app.name} to release #{version} (docker)"

    return fail_with("No release version to roll back to") if version.blank?
    return fail_with("App has no server") unless app.server

    deployment.mark_deploying!
    deployment.update!(release_version: version)

    return false unless image_present?(version)

    @previous_edge_upstream = current_edge_upstream
    return false unless swap_to(version)

    unless republish_edge
      # The old container is already gone, so there is nothing to restore it to —
      # but leaving the edge pointing at a dead target is a silent outage. Say so
      # loudly rather than reporting a completed rollback.
      log "ERROR: the rolled-back container is running but the edge was NOT repointed. " \
          "Public traffic is DOWN until the route is fixed by hand " \
          "(previous upstream: #{@previous_edge_upstream || 'unknown'})."
      return false
    end

    deployment.succeed!
    log "Rollback to #{version} completed"
    true
  rescue StandardError => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  # Fail before touching the running container: a rollback that stops the app and
  # THEN discovers the target image is gone has turned a bad release into an
  # outage.
  def image_present?(version)
    res = @ssh.execute_with_status("docker image inspect #{esc(ref(version))} >/dev/null 2>&1 && echo PRESENT")
    return true if res[:output].to_s.include?("PRESENT")

    fail_with("Image #{ref(version)} is not on #{app.server.name} — it may have aged out " \
              "of the retained releases (keeping #{AppDeployer::RETAINED_RELEASES}).")
    false
  end

  def swap_to(version)
    # Stop whatever is ACTUALLY serving, resolved by label — after a
    # zero-downtime deploy the live container is app-<id>-r<rev>-<sha>, so
    # stopping the legacy fixed name would leave it running and roll back into a
    # split-traffic state.
    live = live_container
    if live.present?
      @ssh.execute_with_status("docker stop #{esc(live)} 2>/dev/null || true")
      @ssh.execute_with_status("docker rm #{esc(live)} 2>/dev/null || true")
    end
    @ssh.execute_with_status("docker stop #{esc(app.container_name)} 2>/dev/null || true")
    @ssh.execute_with_status("docker rm #{esc(app.container_name)} 2>/dev/null || true")

    res = @ssh.execute_with_status(run_command(version))
    if res[:success]
      # `docker run -d` succeeding means the daemon accepted it, not that the
      # process stayed up. Confirm before calling the rollback done.
      check = @ssh.execute_with_status("docker ps -q -f name=#{esc(app.container_name)} | head -n1")
      return true if check[:output].to_s.strip.present?

      fail_with("Rolled-back container #{ref(version)} exited immediately")
      return false
    end

    fail_with("Failed to boot #{ref(version)}: #{res[:stderr].presence || res[:output]}")
    false
  end

  def run_command(version)
    published_port = app.published_port
    runtime_port = app.runtime_port
    parts = [
      "docker run -d",
      "--name #{esc(app.container_name)}",
      "--restart unless-stopped",
      "--label service=#{esc(app.resource_key)}",
      "--label role=web",
      "--label destination=production",
      "--label conductor.infra_revision=#{app.infra_revision}",
      "--label conductor.release=#{esc(version)}",
      "-p #{published_port}:#{runtime_port}"
    ]
    parts << "--network #{esc(app.deploy_network)}" if app.deploy_network.present?
    parts += [ "-e PORT=#{runtime_port}", "-e RAILS_ENV=production", "-e RAILS_LOG_TO_STDOUT=true" ]
    (parts + [ deploy_env_flags, esc(ref(version)) ]).join(" ")
  end

  # A rollback replaces the container, so ANY edge that points at the old one
  # must follow — kamal-proxy by container id, Caddy by host:port. Skipping the
  # Caddy case left the edge on the container we just removed.
  def republish_edge
    return true if app.domain.blank?
    return true if app.server.edge_type.blank? || app.server.edge_type == "none"

    res = @ssh.execute_with_status("docker ps -q -f name=#{esc(app.container_name)} | head -n1")
    container = res[:output].to_s.strip
    return fail_with("Rolled back container did not start — edge not repointed") if container.blank?

    app.update!(container_id: container)

    if app.server.edge_type == "kamal_proxy"
      Edge.for(app.server, ssh: @ssh).publish(domain: app.domain, upstream: "#{container}:#{app.runtime_port}")
    else
      # The rolled-back container binds the app's own port again, so Caddy points
      # back at the stable loopback address.
      Edge.for(app.server).publish(domain: app.domain, upstream: "127.0.0.1:#{app.published_port}")
    end
    true
  rescue StandardError => e
    fail_with("Edge republish failed after rollback: #{e.message}")
    false
  end

  # Recorded before the swap so a failed repoint can name what the edge used to
  # point at — the operator needs that to fix it by hand.
  def current_edge_upstream
    return nil unless app.server.edge_type == "kamal_proxy"

    res = @ssh.execute_with_status("docker exec kamal-proxy kamal-proxy ls 2>/dev/null")
    res[:output].to_s.lines.find { |l| l.include?(app.domain.to_s) }&.strip
  end

  # What is serving now, by the stable service label (ADR 0003/0004).
  def live_container
    res = @ssh.execute_with_status(%(docker ps -q -f "label=service=#{esc(app.resource_key)}" | head -n1))
    res[:output].to_s.strip
  end

  def ref(version) = "#{app.image_name}:#{version}"
  def esc(str) = Shellwords.escape(str.to_s)

  # ONE PLACE, shared with the deploy path. This method used to be a second copy,
  # and the copies had drifted: the deploy path redacted secrets from its logs, this
  # one did not redact at all, so a rollback wrote every credential into the
  # deployment record in clear. Duplicated logic fails in whichever copy nobody reads.
  def deploy_env = @deploy_env ||= DeployEnv.new(app, server: app.server, deployment_id: deployment.id)

  def deploy_env_flags(redacted: false) = deploy_env.flags(redacted: redacted)

  def log(message)
    deployment.append_log(message)
    Rails.logger.info("[docker-rollback] #{message}")
  end

  def fail_with(message)
    @error = message
    log "ERROR: #{message}"
    deployment.fail!(message)
    false
  end
end
