require "shellwords"

class AppDeployer
  attr_reader :app, :deployment, :ssh, :error

  def initialize(app, deployment)
    @app = app
    @deployment = deployment
    @ssh = SshConnection.new(app.server)
  end

  def deploy!
    deployment.start!
    log "Starting deployment for #{app.name}"

    unless app.server&.ssh_configured?
      return fail_with("Server SSH not configured")
    end

    steps = [
      :ensure_docker,
      :clone_or_pull_repo,
      :build_image,
      :stop_old_container,
      :start_container,
      :health_check,
      :republish_edge_route,
      :cleanup
    ]

    steps.each do |step|
      log "Running: #{step.to_s.humanize}"
      unless send(step)
        return fail_with("Step failed: #{step}")
      end
    end

    deployment.succeed!
    log "Deployment completed successfully!"
    broadcast_status("succeeded")
    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  end

  private

  def log(message)
    deployment.append_log(message)
    broadcast(message)
    Rails.logger.info "[Deploy:#{app.slug}] #{message}"
  end

  def broadcast(message)
    timestamp = Time.current.strftime("%H:%M:%S")
    ActionCable.server.broadcast(
      "deployment_#{deployment.id}",
      { type: "log", line: "[#{timestamp}] #{message}\n", status: deployment.status }
    )
  end

  # `display` is what gets logged/broadcast — pass a redacted variant for any
  # command that embeds secrets, so decrypted values never reach the log.
  # Decide success from the command's EXIT STATUS, not from whether it wrote to
  # stderr. git writes normal progress ("Cloning into '…'") to stderr even on
  # exit 0, so the old exec!-based path could neither see a real failure nor
  # trust a real success — execute_with_status captures the exit code and keeps
  # stderr as log output.
  def run(command, display: command)
    log "> #{display}"
    result = ssh.execute_with_status(command)
    if result[:success]
      log result[:output] if result[:output].present?
      true
    else
      log "FAILED (exit #{result[:exit_code]}): #{result[:stderr].presence || result[:output]}"
      false
    end
  end

  def fail_with(message)
    @error = message
    deployment.fail!(message)
    broadcast_status("failed")
    false
  end

  def broadcast_status(status)
    ActionCable.server.broadcast(
      "deployment_#{deployment.id}",
      { type: "status", status: status }
    )
  end

  def app_dir
    "/opt/conductor/apps/#{app.slug}"
  end

  def ensure_docker
    run("which docker || (curl -fsSL https://get.docker.com | sh)")
  end

  def clone_or_pull_repo
    return false unless run("mkdir -p #{app_dir}")

    # Deploy the exact commit recorded on the deployment when one was given (e.g.
    # a webhook's `after` sha) so the audit trail matches what actually shipped —
    # not whatever HEAD happens to be. Fall back to the branch tip otherwise.
    target = deployment.commit_sha.presence || "origin/#{app.branch}"

    # Probe existence with a command that always exits 0 (a missing checkout is
    # not a failure), then branch on the output.
    run("test -d #{app_dir}/.git && echo exists || echo missing")
    ok =
      if ssh.output.to_s.include?("exists")
        run("cd #{app_dir} && git fetch origin && git reset --hard #{target}")
      else
        # Return the CLONE's real result — never leak the `nil` from a trailing
        # `... if commit_sha.present?` on a first deploy (commit_sha is null then),
        # which is what falsely failed the step even though the clone succeeded.
        run("rm -rf #{app_dir} && git clone --branch #{app.branch} #{app.repository_url} #{app_dir}") &&
          (deployment.commit_sha.present? ? run("cd #{app_dir} && git reset --hard #{target}") : true)
      end

    record_shipped_sha if ok
    ok
  end

  # Record what actually shipped, so a docker deploy's audit row carries the sha
  # (the kamal path already does this; the docker path recorded commit_sha: null).
  def record_shipped_sha
    return if deployment.commit_sha.present?

    run("cd #{app_dir} && git rev-parse HEAD")
    sha = ssh.output.to_s[/\b[0-9a-f]{40}\b/]
    deployment.update!(commit_sha: sha) if sha
  end

  # ADR 0003 — the artifact contract. Tag by commit SHA, not just :latest.
  # An immutable tag is what makes a release a THING that can be rolled back to;
  # `:latest` alone means every build destroys its predecessor's identity, which
  # is the entire reason docker apps had no rollback. :latest is kept alongside
  # as a convenience pointer for anything that still expects it.
  def build_image
    deployment.mark_deploying!

    dockerfile = app.dockerfile_path || "Dockerfile"
    tags = [ "-t #{image_ref(release_tag)}" ]
    tags << "-t #{app.image_name}:latest"
    run("cd #{app_dir} && docker build #{tags.join(' ')} -f #{dockerfile} .")
  end

  # The immutable tag for this release. Falls back to the deployment id when no
  # SHA is known, so an image is never left with only a mutable tag.
  def release_tag
    deployment.commit_sha.presence&.first(12) || "d#{deployment.id}"
  end

  def image_ref(tag) = "#{app.image_name}:#{tag}"

  def stop_old_container
    # Stop and remove old container if exists (don't fail if not found)
    run("docker stop #{app.container_name} 2>/dev/null || true")
    run("docker rm #{app.container_name} 2>/dev/null || true")
    true
  end

  def start_container
    port = app.port || 3000

    # Kamal-compatible labels (ADR 0003): `kamal app logs/exec/console` locate a
    # container by its `service` label, never by name — so labelling here is what
    # hands docker apps the whole Kamal ops surface for free. The service value is
    # the STABLE resource key (ADR 0004), not the slug, so a rename can't orphan it.
    prefix = [
      "docker run -d",
      "--name #{app.container_name}",
      "--restart unless-stopped",
      "--label service=#{Shellwords.escape(app.resource_key)}",
      "--label role=web",
      "--label destination=production",
      "--label conductor.infra_revision=#{app.infra_revision}",
      "--label conductor.release=#{Shellwords.escape(release_tag)}",
      "-p #{port}:#{port}"
    ]
    # Join the shared docker network so a container-name DB host (conductor-postgres)
    # resolves — without it the app lands on the default bridge and crash-loops on
    # `could not translate host name`.
    prefix << "--network #{app.deploy_network}" if app.deploy_network.present?
    suffix = [
      "-e PORT=#{port}",
      "-e RAILS_ENV=production",
      "-e RAILS_LOG_TO_STDOUT=true",
      image_ref(release_tag)
    ]
    docker_run = (prefix + [ app.env_variables.map(&:to_docker_env).join(" ") ] + suffix).join(" ")
    # Redact secret env values in the logged/broadcast copy.
    display    = (prefix + [ app.env_variables.map(&:to_docker_env_redacted).join(" ") ] + suffix).join(" ")

    if run(docker_run, display: display)
      # Get container ID
      run("docker ps -q -f name=#{app.container_name}")
      if ssh.output.present?
        app.update!(container_id: ssh.output.strip)
        true
      else
        false
      end
    else
      false
    end
  end

  def health_check
    return true if app.health_check_path.blank?

    port = app.port || 3000
    url = "http://localhost:#{port}#{app.health_check_path}"

    # Wait for container to be ready (max 60 seconds)
    log "Waiting for health check at #{url}"

    6.times do |i|
      sleep 10
      if run("curl -sf #{url} > /dev/null && echo 'healthy'") && ssh.output&.include?("healthy")
        log "Health check passed!"
        return true
      end
      log "Health check attempt #{i + 1}/6 failed, retrying..."
    end

    log "Health check failed after 60 seconds"
    false
  end

  # A docker deploy replaces the container, which changes the container id the
  # edge must point at. kamal-proxy routes to a specific container, so unless the
  # route is republished it keeps targeting the REMOVED container and every
  # request 502s while the deployment happily reports success.
  #
  # Deliberately runs AFTER health_check: the new container is already serving
  # before we move the edge, so the cut-over is the last step and the old target
  # is never dropped in favour of something unproven.
  #
  # Caddy edges are untouched — a host-Caddy route points at a stable host:port,
  # not a container id, so replacing the container is invisible to it.
  def republish_edge_route
    return true if app.domain.blank?
    return true unless app.server&.edge_type == "kamal_proxy"

    container = app.container_id.presence
    return fail_step("no container id recorded — cannot repoint the edge") if container.blank?

    upstream = "#{container}:#{app.port || 3000}"
    log "Republishing #{app.domain} on kamal-proxy -> #{upstream}"
    result = Edge.for(app.server, ssh: ssh).publish(domain: app.domain, upstream: upstream)
    log "Edge published (service=#{result[:service]})"
    true
  rescue Edge::UnsupportedEdge, Edge::KamalProxyAdapter::Error => e
    fail_step("edge republish failed: #{e.message}")
  end

  def fail_step(message)
    log "ERROR: #{message}"
    false
  end

  # Retain prior releases so a rollback target exists (ADR 0003). The previous
  # `docker image prune -f` deleted the very artifact that makes rollback
  # possible — which is why docker apps appeared to "not support" it.
  #
  # Keeps the newest RETAINED_RELEASES tagged images for this app and removes
  # older ones; dangling (untagged) layers are still pruned, since those are
  # genuinely nobody's rollback target.
  RETAINED_RELEASES = 5

  def cleanup
    run(%(docker images --format '{{.Tag}} {{.CreatedAt}}' #{Shellwords.escape(app.image_name)} ) +
        %(| grep -v '^latest ' | sort -k2 -r | tail -n +#{RETAINED_RELEASES + 1} | awk '{print $1}' ) +
        %(| xargs -r -I{} docker rmi #{Shellwords.escape(app.image_name)}:{} 2>/dev/null || true))
    # Dangling layers only — never a tagged release.
    run("docker image prune -f 2>/dev/null || true")
    true
  end
end
