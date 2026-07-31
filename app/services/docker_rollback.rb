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
    return false unless swap_to(version)
    return false unless republish_edge

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
    @ssh.execute_with_status("docker stop #{esc(app.container_name)} 2>/dev/null || true")
    @ssh.execute_with_status("docker rm #{esc(app.container_name)} 2>/dev/null || true")

    res = @ssh.execute_with_status(run_command(version))
    return true if res[:success]

    fail_with("Failed to boot #{ref(version)}: #{res[:stderr].presence || res[:output]}")
    false
  end

  def run_command(version)
    port = app.port || 3000
    parts = [
      "docker run -d",
      "--name #{esc(app.container_name)}",
      "--restart unless-stopped",
      "--label service=#{esc(app.resource_key)}",
      "--label role=web",
      "--label destination=production",
      "--label conductor.infra_revision=#{app.infra_revision}",
      "--label conductor.release=#{esc(version)}",
      "-p #{port}:#{port}"
    ]
    parts << "--network #{esc(app.deploy_network)}" if app.deploy_network.present?
    parts += [ "-e PORT=#{port}", "-e RAILS_ENV=production", "-e RAILS_LOG_TO_STDOUT=true" ]
    (parts + [ app.env_variables.map(&:to_docker_env).join(" "), esc(ref(version)) ]).join(" ")
  end

  # A rollback replaces the container, so a container-targeting edge points at a
  # dead one exactly as it does after a deploy.
  def republish_edge
    return true if app.domain.blank?
    return true unless app.server.edge_type == "kamal_proxy"

    res = @ssh.execute_with_status("docker ps -q -f name=#{esc(app.container_name)}")
    container = res[:output].to_s.strip
    return fail_with("Rolled back container did not start — edge not repointed") if container.blank?

    app.update!(container_id: container)
    Edge.for(app.server, ssh: @ssh).publish(domain: app.domain, upstream: "#{container}:#{app.port || 3000}")
    true
  rescue Edge::UnsupportedEdge, Edge::KamalProxyAdapter::Error => e
    fail_with("Edge republish failed after rollback: #{e.message}")
    false
  end

  def ref(version) = "#{app.image_name}:#{version}"
  def esc(str) = Shellwords.escape(str.to_s)

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
