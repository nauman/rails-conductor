require "shellwords"
require "base64"

class AppDeployer
  # IMPORTANT: this deployer is selected for non-Kamal deploy methods. A Kamal
  # app on a Caddy server is deployed by KamalDeployer, even though its edge is
  # Caddy. Do not put the fleet's Kamal+Caddy cutover guarantee here alone;
  # changes for that shape belong in KamalDeployer's fixed-port path too.
  attr_reader :app, :deployment, :ssh, :error

  def initialize(app, deployment)
    @app = app
    @deployment = deployment
    @ssh = SshConnection.new(app.server)
  end

  # Start the candidate alongside the old container, prove it healthy, swap the
  # edge, and only then drain. Possible ONLY when something can redirect traffic
  # AND the candidate can run without contending for the old container's host
  # port — which is exactly the kamal-proxy case: the proxy targets
  # container:port over the docker network, so the candidate needs no host port
  # at all. See ADR 0003 for why Caddy needs a port dance and an unproxied app
  # cannot have this at all.
  ZERO_DOWNTIME_STEPS = %i[
    ensure_docker prepare_repository_access clone_or_pull_repo build_image
    start_candidate health_check_candidate run_gated_migrations run_seeds_if_requested
    promote_candidate republish_edge_route drain_previous_container cleanup
  ].freeze

  # The original order. Traffic is down from stop_old_container until the edge is
  # republished — unavoidable when the fixed host port IS the service.
  STOP_FIRST_STEPS = %i[
    ensure_docker prepare_repository_access clone_or_pull_repo build_image
    stop_old_container start_container health_check run_gated_migrations run_seeds_if_requested
    republish_edge_route cleanup
  ].freeze

  def deploy!
    deployment.start!
    log "Starting deployment for #{app.name}"

    unless app.server&.ssh_configured?
      return fail_with("Server SSH not configured")
    end

    steps = zero_downtime_cutover? ? ZERO_DOWNTIME_STEPS : STOP_FIRST_STEPS
    log(zero_downtime_cutover? ? "Cutover: candidate → health → swap → drain (no downtime)"
                               : "Cutover: stop-first (this app's shape cannot avoid a brief outage)")

    steps.each do |step|
      log "Running: #{step.to_s.humanize}"
      unless send(step)
        return fail_with("Step failed: #{step}")
      end
    end

    # Record the EXACT tag that shipped. Deployment.rollbackable requires it, so
    # without this a docker deploy could never appear as a rollback target — the
    # rollback engine existed but nothing could reach it. It must be the tag we
    # actually built, not the full SHA, or the rollback inspects an image that
    # does not exist.
    deployment.update!(release_version: release_tag)
    deployment.succeed!
    log "Deployment completed successfully (release #{release_tag})"
    broadcast_status("succeeded")
    true
  rescue => e
    fail_with("Unexpected error: #{e.message}")
  ensure
    cleanup_repository_access
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
    app.app_dir
  end

  def ensure_docker
    run("which docker || (curl -fsSL https://get.docker.com | sh)")
  end

  # Private repositories use the app's existing read-only deploy key. Materialize
  # it only on the target host, with restrictive permissions, and redact the key
  # bytes from every deployment log/broadcast. Public repositories need no setup.
  def prepare_repository_access
    key = app.deploy_key&.private_key
    return true if key.blank?

    @repository_key_path = "/home/#{app.server.ssh_user_or_default}/.conductor/keys/#{app.resource_key}"
    key_dir = File.dirname(@repository_key_path)
    encoded = Base64.strict_encode64(key)
    command =
      "mkdir -p #{esc(key_dir)} && chmod 700 #{esc(key_dir)} && " \
      "printf %s #{esc(encoded)} | base64 -d > #{esc(@repository_key_path)} && " \
      "chmod 600 #{esc(@repository_key_path)}"
    display =
      "mkdir -p #{esc(key_dir)} && chmod 700 #{esc(key_dir)} && " \
      "[REDACTED deploy key] > #{esc(@repository_key_path)} && chmod 600 #{esc(@repository_key_path)}"

    run(command, display: display)
  end

  def clone_or_pull_repo
    return false unless run("mkdir -p #{esc(app_dir)}")

    # Deploy the exact commit recorded on the deployment when one was given (e.g.
    # a webhook's `after` sha) so the audit trail matches what actually shipped —
    # not whatever HEAD happens to be. Fall back to the branch tip otherwise.
    target = deployment.commit_sha.presence || "origin/#{app.branch}"

    # Probe existence with a command that always exits 0 (a missing checkout is
    # not a failure), then branch on the output.
    run("test -d #{esc(app_dir)}/.git && echo exists || echo missing")
    ok =
      if ssh.output.to_s.include?("exists")
        run("cd #{esc(app_dir)} && #{set_repository_origin}#{git_prefix}git fetch origin && git reset --hard #{esc(target)}")
      else
        # Return the CLONE's real result — never leak the `nil` from a trailing
        # `... if commit_sha.present?` on a first deploy (commit_sha is null then),
        # which is what falsely failed the step even though the clone succeeded.
        run("rm -rf #{esc(app_dir)} && #{git_prefix}git clone --branch #{esc(app.branch)} #{esc(repository_url)} #{esc(app_dir)}") &&
          (deployment.commit_sha.present? ? run("cd #{esc(app_dir)} && git reset --hard #{esc(target)}") : true)
      end

    record_shipped_sha if ok
    ok
  end

  def repository_url
    @repository_key_path ? DeployKey.ssh_url(app.repository_url) : app.repository_url
  end

  def set_repository_origin
    @repository_key_path ? "git remote set-url origin #{esc(repository_url)} && " : ""
  end

  def git_prefix
    return "" unless @repository_key_path

    ssh_command = "ssh -i #{@repository_key_path} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
    "GIT_SSH_COMMAND=#{esc(ssh_command)} "
  end

  def cleanup_repository_access
    return if @repository_key_path.blank?

    ssh.execute_with_status("rm -f #{esc(@repository_key_path)}")
  rescue StandardError => e
    log "WARNING: could not remove temporary repository key: #{e.message}"
  ensure
    @repository_key_path = nil
  end

  # Record what actually shipped, so a docker deploy's audit row carries the sha
  # (the kamal path already does this; the docker path recorded commit_sha: null).
  def record_shipped_sha
    return if deployment.commit_sha.present?

    run("cd #{esc(app_dir)} && git rev-parse HEAD")
    sha = ssh.output.to_s[/\b[0-9a-f]{40}\b/]
    deployment.update!(commit_sha: sha) if sha
  end

  # ADR 0003 — the artifact contract. Tag by commit SHA, not just :latest.
  # An immutable tag is what makes a release a THING that can be rolled back to;
  # `:latest` alone means every build destroys its predecessor's identity, which
  # is the entire reason docker apps had no rollback. :latest is kept alongside
  # as a convenience pointer for anything that still expects it.
  # The docker path builds ON THE TARGET — `run` is SSH to the app's own server —
  # so this build competes with whatever that box is already serving. Record it as
  # the fact it is; a status read that says "control machine" for these is wrong.
  def record_target_build
    host = "target-server:#{app.server&.ip_address}"
    app.update_columns(build_host: host) if app.build_host != host
  end

  def build_image
    record_target_build
    deployment.mark_deploying!

    dockerfile = app.dockerfile_path || "Dockerfile"
    tags = [ "-t #{esc(image_ref(release_tag))}" ]
    tags << "-t #{esc("#{app.image_name}:latest")}"
    run("cd #{esc(app_dir)} && docker build #{tags.join(' ')} -f #{esc(dockerfile)} .")
  end

  # The immutable tag for this release. Falls back to the deployment id when no
  # SHA is known, so an image is never left with only a mutable tag.
  def release_tag
    deployment.commit_sha.presence&.first(12) || "d#{deployment.id}"
  end

  def image_ref(tag) = "#{app.image_name}:#{tag}"

  # Every value below is operator-editable and reaches a REMOTE SHELL. slug is
  # format-validated at the model, but repository_url, branch, dockerfile_path,
  # image_name, health_check_path and the docker network are not — so escaping
  # here is the boundary, not a nicety.
  def esc(value) = Shellwords.escape(value.to_s)

  # ONE PLACE, shared with DockerRollback. This used to be a second copy of that
  # logic and the two had already drifted — this one redacted secrets from the log,
  # the rollback one did not redact at all, so a rollback wrote every credential into
  # the deployment record in clear.
  #
  # Sensitive values now travel in a 0600 file uploaded over scp rather than as `-e`
  # arguments, so they are not readable in the host process table for the life of the
  # command. They ARE still in the container's environment and still visible to
  # `docker inspect` — inherent to env vars, and stated so the flag cannot
  # over-promise.
  def deploy_env = @deploy_env ||= DeployEnv.new(app, server: app.server, deployment_id: deployment.id)

  def deploy_env_flags(redacted: false) = deploy_env.flags(redacted: redacted)

  # Uploaded before the container is created; removed afterwards on BOTH paths,
  # success and failure — a 0600 file of live credentials outliving the thing that
  # needed it is the worse outcome.
  def upload_env_file!
    return true unless deploy_env.file_needed?
    return true if deploy_env.upload!(ssh)

    fail_with("could not write the environment file to #{app.server.name}: #{ssh.error}")
    false
  end

  def remove_env_file! = deploy_env.remove!(ssh)

  # Stop whatever is actually serving, resolved by label — not just the fixed
  # name. An app that previously deployed zero-downtime runs as
  # app-<id>-r<rev>-<sha>, and it can fall back to this path by losing its
  # domain, edge or network. Stopping only conductor-<slug> would then leave the
  # old release running: two releases at once, or a port conflict on start.
  def stop_old_container
    # ALL of them, not the first. The shared resolver returns one id (head -n1),
    # which left a second leftover running — exactly the split-container/port
    # conflict this step exists to prevent.
    keys = ([ app.resource_key ] + app.kamal_service_candidates).uniq.map { |k| esc(k) }.join(" ")
    run(%(for s in #{keys}; do ) +
        %(for cid in $(docker ps -aq -f "label=service=$s"); do ) +
        %(docker stop "$cid" >/dev/null 2>&1; docker rm "$cid" >/dev/null 2>&1; done; done; true))
    # And the fixed name, for anything the label lookup could not see.
    run("docker stop #{Shellwords.escape(app.container_name)} 2>/dev/null || true")
    run("docker rm #{Shellwords.escape(app.container_name)} 2>/dev/null || true")
    true
  end

  def start_container
    published_port = app.published_port
    runtime_port = app.runtime_port

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
      "-p #{published_port}:#{runtime_port}"
    ]
    # Join the shared docker network so a container-name DB host (conductor-postgres)
    # resolves — without it the app lands on the default bridge and crash-loops on
    # `could not translate host name`.
    prefix << "--network #{esc(app.deploy_network)}" if app.deploy_network.present?
    suffix = [
      "-e PORT=#{runtime_port}",
      "-e RAILS_ENV=production",
      "-e RAILS_LOG_TO_STDOUT=true",
      esc(image_ref(release_tag))
    ]
    docker_run = (prefix + [ deploy_env_flags ] + suffix).join(" ")
    # Redact secret env values in the logged/broadcast copy.
    display    = (prefix + [ deploy_env_flags(redacted: true) ] + suffix).join(" ")

    return false unless upload_env_file!

    created = run(docker_run, display: display)
    remove_env_file!

    if created
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

  # Zero-downtime needs two things: something that can redirect traffic, and a way
  # for the candidate to run without contending for the old container's host port.
  #
  #   kamal_proxy — targets container:port over the docker network, so the
  #                 candidate needs NO host port. Free.
  #   caddy       — targets host:port, so the candidate takes a SECOND, ephemeral
  #                 host port; Caddy is repointed at it, then the old one drains.
  #   otherwise   — the fixed host port IS the service. Nothing to swap; downtime
  #                 is a property of the app's shape, not a missing feature.
  def zero_downtime_cutover?
    return false if app.domain.blank?

    case app.server&.edge_type
    when "kamal_proxy" then app.deploy_network.present?
    when "caddy"       then true
    else false
    end
  end

  def proxy_targets_container? = app.server&.edge_type == "kamal_proxy"

  # A high, deterministic-ish port derived from the app id, so a candidate never
  # collides with the live port or with another app's candidate. Probed for
  # availability before use rather than assumed.
  def candidate_host_port
    @candidate_host_port ||= begin
      # 10-wide, non-overlapping windows. The previous `app.id % 20_000` gave
      # adjacent ids overlapping ranges (app 1 → 20001..20005, app 2 → 20002..).
      base = 20_000 + ((app.id % 4_000) * 10)
      found = nil
      10.times do |i|
        port = base + i
        # Ask docker rather than `ss`: it is certainly present where we are about
        # to run a container, and `ss ... || echo FREE` reported a MISSING ss as
        # "free" — exactly backwards, and it would then fail to bind.
        run("docker ps --format '{{.Ports}}' | grep -q ':#{port}->' && echo BUSY || echo MAYBE_FREE")
        next unless ssh.output.to_s.include?("MAYBE_FREE")

        found = port
        break
      end
      found
    end
  end

  # Boot the new release under its own release-scoped name, with NO host port
  # binding — the proxy reaches it over the docker network, so it can run
  # alongside the container currently serving.
  def start_candidate
    @previous_container = resolve_serving_container
    log "Previous container: #{@previous_container.presence || '(none)'}"

    runtime_port = app.runtime_port
    name = app.release_container_name(deployment.commit_sha, deployment_id: deployment.id)

    # A retry can find a same-named candidate from a previous attempt. Removing it
    # blindly is an outage: if that attempt died between publishing the edge and
    # draining, the "leftover" candidate is what is SERVING. Only reclaim a
    # candidate the edge is not pointing at.
    if @previous_container.present? && @previous_container == container_id_of(name)
      log "Candidate #{name} is the current serving container — reusing it rather than replacing"
      @candidate_name = name
      @candidate_container = @previous_container
      # A survivor of an earlier attempt may still be `--restart no` while already
      # serving. Repair that here rather than waiting for the promotion step: this
      # container is carrying traffic NOW, and every step between here and promotion
      # is a chance for the process to die and leave it unable to come back.
      run("docker update --restart unless-stopped #{Shellwords.escape(@candidate_container)}")
      return true
    end
    run("docker rm -f #{Shellwords.escape(name)} 2>/dev/null || true")

    prefix = [
      "docker run -d",
      "--name #{Shellwords.escape(name)}",
      # BORN EPHEMERAL, PROMOTED LATER (ADR 0006). A candidate is a thing that has
      # not won yet, and `unless-stopped` means "come back on daemon start unless a
      # human explicitly stopped you" — which nobody does to a deploy that failed
      # halfway. One candidate created this way outlived its abandoned cutover by
      # fifteen days, returning with every reboot and executing production jobs on
      # stale code. `--restart no` means the next reboot leaves it stopped instead
      # of resurrecting it, and #promote_candidate raises it to unless-stopped the
      # moment the edge starts serving it.
      "--restart no",
      *candidate_placement,
      "--label service=#{Shellwords.escape(app.resource_key)}",
      "--label role=web",
      "--label destination=production",
      "--label conductor.infra_revision=#{app.infra_revision}",
      "--label conductor.release=#{Shellwords.escape(release_tag)}",
      "--label conductor.candidate=true"
    ]
    suffix = [ "-e PORT=#{runtime_port}", "-e RAILS_ENV=production", "-e RAILS_LOG_TO_STDOUT=true", image_ref(release_tag) ]
    cmd = (prefix + [ deploy_env_flags ] + suffix).join(" ")
    display = (prefix + [ deploy_env_flags(redacted: true) ] + suffix).join(" ")

    return false unless upload_env_file!

    started = run(cmd, display: display)
    # Whether or not it started, the file has done its job — and leaving a 0600 file
    # of live credentials behind on the failure path is the worse outcome.
    remove_env_file!
    return false unless started

    @candidate_name = name # set BEFORE the probe so any later failure can clean up
    @candidate_container = container_id_of(name)
    return discard_candidate("candidate did not start") if @candidate_container.blank?

    true
  end

  def container_id_of(name)
    run("docker ps -q -f name=#{Shellwords.escape(name)} | head -n1")
    ssh.output.to_s.strip
  end

  def candidate_running?
    @candidate_container.present? && container_id_of(@candidate_name).present?
  end

  # Where the candidate is reachable while it proves itself.
  def candidate_placement
    if proxy_targets_container?
      # No host port at all — the proxy reaches it over the docker network.
      [ "--network #{Shellwords.escape(app.deploy_network)}" ]
    else
      port = candidate_host_port
      raise "no free host port in this app's candidate window" if port.nil?

      parts = [ "-p 127.0.0.1:#{port}:#{app.runtime_port}" ]
      parts << "--network #{Shellwords.escape(app.deploy_network)}" if app.deploy_network.present?
      parts
    end
  end

  # Health-check the candidate over the docker network, by its container IP —
  # it has no host port to probe. Failure removes the candidate and leaves the
  # old container serving, so a bad release is a failed deploy, not an outage.
  def health_check_candidate
    # Whatever else happens, the candidate must be recorded as the thing the edge
    # will point at BEFORE the edge moves. Returning early without doing so
    # republished the OLD container id and then drained that container — a
    # deploy that reports success with nothing serving.
    return discard_candidate("candidate is not running") unless candidate_running?

    app.update!(container_id: @candidate_container)

    if app.health_check_path.blank?
      log "No health_check_path set — cutting over on running-state alone (configure one to gate this properly)"
      return true
    end

    url = candidate_health_url
    return discard_candidate("could not resolve the candidate's address") if url.nil?
    log "Health-checking candidate at #{url}"

    6.times do |i|
      sleep 5
      if run("curl -sf --max-time 5 #{Shellwords.escape(url)} > /dev/null && echo healthy") &&
         ssh.output.to_s.include?("healthy")
        log "Candidate healthy — safe to cut over"
        return true
      end
      log "Candidate health attempt #{i + 1}/6 failed, retrying..."
    end

    discard_candidate("candidate never became healthy")
  end

  def candidate_health_url
    port = app.runtime_port
    return "http://127.0.0.1:#{candidate_host_port}#{app.health_check_path}" unless proxy_targets_container?

    run("docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' #{Shellwords.escape(@candidate_name)}")
    ip = ssh.output.to_s.split.first
    return nil if ip.blank?

    "http://#{ip}:#{port}#{app.health_check_path}"
  end

  # The old container only goes once traffic is already on the candidate.
  # PROMOTE BEFORE THE EDGE MOVES. This took three attempts to place, and the two
  # wrong ones are the argument for where it is now.
  #
  # Promoting after the drain left the candidate serving as production while still
  # `--restart no`, with the incumbent already deleted — an interruption there left
  # production both ephemeral and irreplaceable. Promoting after the edge swap
  # merely narrowed that window instead of closing it, and left a genuinely
  # inconsistent terminal state on failure: edge on the candidate, deploy marked
  # failed, nothing serving durably.
  #
  # Running BEFORE republish_edge_route removes the window entirely. The candidate
  # has passed its health check but carries no traffic yet, so a failure here costs
  # nothing: the edge has not moved, the incumbent is still serving, and the normal
  # cutover compensation discards the candidate. There is never an instant where
  # something serving production is `--restart no`.
  #
  # The cost is the mirror risk — a promoted candidate that never wins would survive
  # a reboot as an orphan. That window is two steps wide and covered by
  # #compensate_failed_cutover, and an orphan is now DETECTED by release comparison,
  # while an ephemeral production container is an outage nobody is watching for.
  # Given one of the two must exist, this is the one to keep.
  #
  # NOT a relabel. Docker labels are immutable after creation, so the container
  # cannot be re-badged and `conductor.candidate=true` stays on it for life. That is
  # why identity is decided by comparing the container's `conductor.release` against
  # Conductor's own last successful deployment, never by trusting the label — see
  # ResidueDetector#check_live_candidate_containers, which reported a live release as
  # an orphan back when it trusted it.
  def promote_candidate
    return true if @candidate_container.blank?

    if run("docker update --restart unless-stopped #{Shellwords.escape(@candidate_container)}")
      log "Promoted #{@candidate_name} to a release: restart policy is now unless-stopped"
      return true
    end

    # THE CANDIDATE MAY BE THE INCUMBENT. The reuse branch adopts a container that is
    # already carrying traffic, and discarding it here would `docker rm -f` the live
    # site to fix a restart policy. Fail loudly and touch nothing: a container that
    # serves but would not survive a reboot is a problem to repair by hand, not an
    # outage to cause on purpose.
    if @candidate_container == @previous_container
      return fail_step("#{@candidate_name} is ALREADY SERVING and could not be promoted to " \
                       "`--restart unless-stopped`. It has deliberately NOT been removed — it is the " \
                       "live container. It will not come back after a reboot until you run " \
                       "`docker update --restart unless-stopped #{@candidate_name}` on the box.")
    end

    # Otherwise nothing has moved yet, so this is an ordinary pre-cutover failure:
    # discard the candidate and leave the incumbent serving, exactly as a failed
    # health check does. Restore the recorded container first — leaving container_id
    # pointing at a container about to be removed is how the record starts lying.
    app.update!(container_id: @previous_container.presence)
    discard_candidate("#{@candidate_name} could not be promoted to `--restart unless-stopped`, " \
                      "so it would not survive a reboot — refusing to move traffic onto it")
  end

  def drain_previous_container
    return true if @previous_container.blank?
    return true if @previous_container == @candidate_container

    log "Draining previous container #{@previous_container}"
    stopped = run("docker stop #{Shellwords.escape(@previous_container)} 2>/dev/null || true")
    removed = run("docker rm #{Shellwords.escape(@previous_container)} 2>/dev/null || true")
    # The fixed legacy name must be free for the next stop-first deploy, and a
    # dead container holding it would also confuse the ops CLI.
    run("docker rm -f #{Shellwords.escape(app.container_name)} 2>/dev/null || true")

    # Traffic is already on the candidate, so a failed drain is not an outage —
    # but it leaves two containers running, which must not pass as success.
    return true if stopped && removed

    fail_step("traffic moved to the new release, but draining #{@previous_container} failed — " \
              "both containers may still be running; remove the old one by hand")
  end

  # Whatever is serving right now: the labelled container if there is one,
  # otherwise the legacy fixed name (apps deployed before ADR 0003/0004).
  def resolve_serving_container
    run("docker ps -q -f label=service=#{Shellwords.escape(app.resource_key)} | head -n1")
    found = ssh.output.to_s.strip
    return found if found.present?

    run("docker ps -q -f name=#{Shellwords.escape(app.container_name)} | head -n1")
    ssh.output.to_s.strip
  end

  def discard_candidate(reason)
    log "ERROR: #{reason} — removing the candidate; the previous release keeps serving"
    run("docker rm -f #{Shellwords.escape(@candidate_name)} 2>/dev/null || true") if @candidate_name.present?
    false
  end

  def health_check
    return true if app.health_check_path.blank?

    url = "http://localhost:#{app.published_port}#{app.health_check_path}"

    # Wait for container to be ready (max 60 seconds)
    log "Waiting for health check at #{url}"

    6.times do |i|
      sleep 10
      if run("curl -sf #{esc(url)} > /dev/null && echo 'healthy'") && ssh.output&.include?("healthy")
        log "Health check passed!"
        return true
      end
      log "Health check attempt #{i + 1}/6 failed, retrying..."
    end

    log "Health check failed after 60 seconds"
    false
  end

  # A Kamal artifact still carries the Rails release contract even though Kamal
  # no longer drives the roll. Run the schema gate inside the proven candidate
  # before traffic moves. Plain Docker artifacts may not be Rails applications,
  # so they retain their existing opt-out until migrations become an explicit
  # capability instead of an artifact convention.
  def run_gated_migrations
    return true unless app.kamal?

    log "=== gated migrations: bin/rails db:migrate ==="
    unless run_in_release("bin/rails db:migrate")
      return fail_release_gate("db:migrate failed — the previous release keeps serving")
    end

    unless run_in_release("bin/rails db:abort_if_pending_migrations")
      return fail_release_gate("pending migrations remain after db:migrate — the previous release keeps serving")
    end

    true
  end

  def run_seeds_if_requested
    return true unless app.seed_on_next_deploy?

    log "=== running seeds (requested): bin/rails db:seed ==="
    digest = seeds_digest
    succeeded = run_in_release("bin/rails db:seed")
    output = ssh.output.to_s.last(4000)

    app.seed_applications.create!(
      status: succeeded ? "succeeded" : "failed",
      digest: digest,
      applied_at: Time.current,
      output: output
    )
    app.update_columns(seed_on_next_deploy: false)

    return true if succeeded

    fail_release_gate("db:seed failed — seed run recorded as failed; the previous release keeps serving")
  end

  def run_in_release(command)
    run("docker exec #{esc(release_container_name)} #{command}")
  end

  def release_container_name
    @candidate_name.presence || app.container_name
  end

  def seeds_digest
    return nil unless run("test -f #{esc(app_dir)}/db/seeds.rb && sha256sum #{esc(app_dir)}/db/seeds.rb || true")

    ssh.output.to_s[/\b[0-9a-f]{64}\b/]
  end

  # Before edge publication, a failed release gate is compensatable: restore
  # the recorded incumbent and discard only the unserved candidate. Stop-first
  # shapes have no incumbent left to preserve, so leave their running container
  # available for diagnosis while still failing the deployment.
  def fail_release_gate(message)
    unless @candidate_name.present?
      log "ERROR: #{message}"
      return false
    end

    app.update!(container_id: @previous_container.presence) if @previous_container != @candidate_container
    discard_candidate(message)
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

    case app.server&.edge_type
    when "kamal_proxy"
      # The proxy targets the container itself, so it MUST move on every
      # replacement — this is the observed production failure.
      container = app.container_id.presence
      return fail_step("no container id recorded — cannot repoint the edge") if container.blank?

      publish_edge("#{container}:#{app.runtime_port}")
    when "caddy"
      # Caddy targets a loopback host:port. On the zero-downtime path that is the
      # candidate's ephemeral port; on the stop-first path the app's own port is
      # unchanged, so there is nothing to repoint.
      return true unless zero_downtime_cutover? && @candidate_host_port

      publish_edge("127.0.0.1:#{@candidate_host_port}", incumbent_upstream: "127.0.0.1:#{app.published_port}")
    else
      true
    end
  end

  def publish_edge(upstream, incumbent_upstream: nil)
    # Adapters take different collaborators: kamal-proxy runs over SSH, Caddy
    # talks to its Admin API. Only pass what the chosen edge accepts.
    edge = proxy_targets_container? ? Edge.for(app.server, ssh: ssh) : Edge.for(app.server)
    domains = [ app.domain ]
    if incumbent_upstream && edge.respond_to?(:managed_domains_for_upstream)
      domains.concat(edge.managed_domains_for_upstream(incumbent_upstream))
    end
    domains.compact_blank.uniq.each do |domain|
      log "Republishing #{domain} (#{app.server.edge_type}) -> #{upstream}"
      result = edge.publish(domain: domain, upstream: upstream)
      log "Edge published (#{result[:service] || result[:route_id]})"
    end
    true
  # Any edge failure, not just the two typed ones — reaching the outer rescue
  # would skip compensation and strand both the candidate and a database row
  # pointing at a container that never took traffic.
  rescue StandardError => e
    compensate_failed_cutover
    fail_step("edge republish failed: #{e.message}")
  end

  # Undo what a half-finished cutover changed. The old container is still serving
  # and the edge still points at it, so the candidate must go and the recorded
  # container id must go back.
  def compensate_failed_cutover
    return if @candidate_name.blank?

    app.update!(container_id: @previous_container.presence) if @previous_container != @candidate_container
    discard_candidate("cutover failed after the candidate started")
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
    # Keep the tags of the last RETAINED_RELEASES SUCCESSFUL deploys, not merely
    # the newest images: every failed candidate build also produces a tag, so a
    # run of failures would otherwise evict the known-good rollback targets the
    # retention count promises.
    # Scoped to this runtime: a Kamal-era release consuming a docker app's slots
    # would evict genuinely usable rollback targets.
    keep = app.deployments.rollbackable_for(app).limit(RETAINED_RELEASES).filter_map(&:release_version)
    keep = (keep + [ release_tag ]).uniq.map { |t| Shellwords.escape(t) }
    keep_pattern = keep.map { |t| "-e '^#{t}$'" }.join(" ")

    run(%(docker images --format '{{.Tag}}' #{Shellwords.escape(app.image_name)} ) +
        %(| grep -v '^latest$' | grep -v #{keep_pattern} ) +
        %(| xargs -r -I{} docker rmi #{Shellwords.escape(app.image_name)}:{} 2>/dev/null || true))
    # Dangling layers only — never a tagged release we intend to keep.
    run("docker image prune -f 2>/dev/null || true")
    true
  end
end
