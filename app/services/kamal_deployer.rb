require "shellwords"
require "fileutils"
require "base64"
require "digest"

# Deploys a kamal-managed app with **Conductor's own container as the Kamal
# control machine** (Kamal is a control-machine tool; target servers are deploy
# targets that need only docker, not ruby/kamal).
#
# Flow (all local to Conductor's container):
#   1. checkout/refresh the app repo into a workspace
#   2. generate .kamal/secrets from the app's EnvVariables (Conductor = source of
#      truth for secret values — see KamalEnvWriter)
#   3. materialize the target server's SSH key so Kamal (net-ssh) can reach it
#   4. run Kamal locally as the control process; the legacy deploy environment
#      still routes BuildKit over SSH to the target, then Kamal SSHes there to
#      boot the release (build/roll executor separation is the open replacement)
#
# Infra prerequisites (see docs/roadmap/plan-kamal-control-machine.html):
#   - the `kamal` gem in Conductor's bundle
#   - docker CLI in the image + the host's /var/run/docker.sock mounted in
#   - the app repo reachable (public, or a deploy key/token — separate backlog item)
class KamalDeployer
  attr_reader :app, :deployment, :error

  # Recorded in apps.build_host. A literal, not a description, so it can be
  # compared — App#builds_on_a_serving_box? keys off it.
  CONTROL_MACHINE = "control-machine".freeze

  # allow_self_deploy: escape hatch for the one legitimate in-product self-deploy
  # caller — a deliberate, supervised override. Every routine path (webhook,
  # job, MCP, UI) leaves it false so a self-managed app cannot deploy itself.
  def initialize(app, deployment, shell: nil, ssh: nil, target_server: nil, allow_self_deploy: false)
    @app = app
    @deployment = deployment
    @shell = shell || LocalShell.new
    # Only used to free a stuck published port before boot (see #release_fixed_port).
    # Everything else reaches the box through kamal, not directly.
    @injected_ssh = ssh
    @allow_self_deploy = allow_self_deploy
    # The destination host. Defaults to the app's own server; an app transfer
    # (spec 26) passes a different server to stand the app up on box B. Threads
    # through the SSH/env/key setup AND the generated deploy overlay.
    @target_server = target_server
  end

  # The server this deploy targets — the app's own, unless a transfer overrides it.
  def deploy_server = @target_server || app.server

  def deploy!
    deployment.start!
    log "Deploying #{app.name} via Kamal (control machine: Conductor)"

    return fail_with("App has no repository_url") if app.repository_url.blank?
    return fail_with("App has no target host") if deploy_server&.ip_address.blank?

    deployment.mark_deploying!
    FileUtils.mkdir_p(workspace)
    @key_file = write_ssh_key
    @deploy_key_file = write_deploy_key
    @clone_token = resolve_clone_token
    @askpass_file = @clone_token ? write_askpass(@clone_token) : nil
    @ssh_home = setup_ssh_home

    # Pin the intended target commit up front, straight from the remote, so the
    # build is deterministic and visible. A plain `fetch + reset --hard origin/<branch>`
    # ships whatever the moving branch ref resolves to at fetch time — which can lag
    # the batch the operator meant to ship — and nothing downstream asserts otherwise,
    # so a stale image can boot under a green "succeeded". See the drift guard below.
    @target_sha = resolve_target_sha
    if @target_sha.present?
      deployment.update!(commit_sha: @target_sha)
      log "Target commit: #{@target_sha} (#{app.branch.presence || 'main'} @ origin, resolved via ls-remote)"
    else
      log "WARNING: could not resolve target commit via ls-remote; falling back to origin/#{app.branch.presence || 'main'} (no drift guard)"
    end

    return false unless run_step("Syncing repo", sync_repo_command, env: git_env)
    return false unless verify_synced_head
    # Caddy is only the edge; Kamal still owns this deploy transaction. The
    # Caddy-specific post-boot route assertion must run in this class, not in
    # AppDeployer: deploy_method=kamal always reaches KamalDeployer. The Caddy
    # path reuses one fixed host port, so it must validate every hostname after
    # boot rather than looking for a changed candidate port.
    return false unless verify_proxy_off_on_caddy_edge
    record_commit_sha
    return false unless verify_required_secrets
    materialize_master_key
    write_secrets_file
    write_self_describing_config if app.self_describing?
    record_build_location
    log_ssh_diagnostics
    # Belt and braces with the webhook guard: a self-managed app must not deploy
    # itself from inside the container kamal is about to replace. The killed
    # process strands the deploy lock and blocks every later deploy, and the boot
    # reconciler then records the row "succeeded" without the gated migrations
    # below ever having run. CI is the only supported path for these.
    if app.self_managed? && !@allow_self_deploy
      fail_with("self-managed apps deploy from CI, not in-product — refusing to self-deploy " \
                "(see docs/learnings/deploy-lock-stranded-by-self-deploy.md)")
      return false
    end
    note_self_deploy if app.self_managed?
    return false unless prepare_caddy_edge
    return false unless build_before_fixed_port_stop
    return false unless stop_prior_container_if_fixed_port
    unless run_kamal_deploy(prebuilt: fixed_port_app?)
      recover_after_stop_first
      return false
    end
    return false unless run_gated_migrations
    return false unless run_seeds_if_requested
    return false unless reconcile_caddy_edge

    prune_dead_boot_artifacts

    # Record the version this release booted — for Kamal that's the deployed sha,
    # which Kamal tags its images with and `kamal rollback <version>` can boot again.
    deployment.update!(release_version: deployment.commit_sha) if deployment.commit_sha.present?
    deployment.succeed!
    log "Kamal deployment completed successfully!"
    broadcast_status("succeeded")
    true
  rescue StandardError => e
    fail_with("Unexpected error: #{e.message}")
  ensure
    cleanup_key
  end

  # Boot a previously-shipped Kamal release again. Kamal retains prior versioned
  # images on the target host, so this reuses the same workspace / SSH / secrets
  # setup as #deploy! but runs `kamal rollback <version>` — no git rebuild, just
  # re-booting the image already tagged <version> on the host.
  def rollback!(version)
    deployment.start!
    log "Rolling back #{app.name} to release #{version} via Kamal (control machine: Conductor)"

    return fail_with("App has no repository_url") if app.repository_url.blank?
    return fail_with("App has no target host") if deploy_server&.ip_address.blank?
    return fail_with("No release version to roll back to") if version.blank?

    deployment.mark_deploying!
    deployment.update!(commit_sha: version, release_version: version)
    FileUtils.mkdir_p(workspace)
    @key_file = write_ssh_key
    @deploy_key_file = write_deploy_key
    @clone_token = resolve_clone_token
    @askpass_file = @clone_token ? write_askpass(@clone_token) : nil
    @ssh_home = setup_ssh_home

    # Kamal reads config/deploy.yml + .kamal/secrets from the checkout to know the
    # host/registry/service — sync the repo (current branch HEAD; config only, the
    # target image is NOT rebuilt) and materialize secrets, exactly as a deploy would.
    return false unless run_step("Syncing repo", sync_repo_command, env: git_env)
    return false unless verify_required_secrets
    materialize_master_key
    write_secrets_file
    write_self_describing_config if app.self_describing?
    log_ssh_diagnostics

    return false unless run_kamal_rollback(version)

    deployment.succeed!
    log "Rollback to #{version} completed successfully!"
    broadcast_status("succeeded")
    true
  rescue StandardError => e
    fail_with("Unexpected error: #{e.message}")
  ensure
    cleanup_key
  end

  private

  def run_step(label, command, chdir: nil, env: {})
    log "Running: #{label}"
    result = @shell.run(*command, chdir: chdir, env: env) { |line| log(line) }
    return true if result.success?

    fail_with("#{label} failed (exit #{result.exit_code})")
    false
  end

  # Fail fast with a clear, actionable error when a required secret can't be
  # resolved. Without this, kamal fails deep in the run with a cryptic message
  # (e.g. an empty `docker login -p` when KAMAL_REGISTRY_PASSWORD is absent).
  #
  # A secret is satisfied if it's an app env var, OR — for a self-managed deploy —
  # already present in Conductor's own container env (its deploy.yml injects the
  # same secrets), OR it's RAILS_MASTER_KEY we can materialize from that env.
  def verify_required_secrets
    # Include derived secrets (e.g. a dedicated app's DATABASE_URL) so preflight
    # doesn't demand a key Conductor already injects — deploy_env_pairs is the
    # single source of what actually lands in .kamal/secrets.
    provided = app.deploy_env_pairs(server: deploy_server).map(&:first).to_set
    missing = required_secrets.reject do |key|
      provided.include?(key) || (app.self_managed? && resolvable_from_conductor_env?(key))
    end
    unless missing.empty?
      fail_with("Missing required env var(s): #{missing.join(', ')}. " \
                "Add them under the app's Environment Variables (mark as secret), then redeploy.")
      return false
    end

    verify_managed_master_key
  end

  # Rails checks the master key's LENGTH and nothing else:
  # `ActiveSupport::EncryptedFile#check_key_length` raises only when the key is not
  # exactly 32 characters, and the key is then used as `[key].pack("H*")`. A key
  # outside 0-9a-f still unpacks deterministically, so it encrypts and decrypts
  # perfectly well provided the same string is used for both.
  #
  # This guard used to require 32 HEX characters, which is stricter than Rails and
  # rejected a key Rails accepts — a live app running happily on a 32-character
  # non-hex key could not be deployed, two days after the rule landed, with an
  # error telling the operator their correct key was wrong. A validator must not be
  # stricter than the thing it is validating for.
  #
  # The purpose it was added for still holds and is preserved: a SECRET_KEY_BASE
  # pasted into this slot is 128 characters, so length alone catches it. That
  # matters on a fixed-port adoption, where the old owner is stopped before Rails
  # would report a malformed key during container boot.
  MASTER_KEY_LENGTH = 32

  def verify_managed_master_key
    key = app.deploy_env_pairs(server: deploy_server).to_h["RAILS_MASTER_KEY"]
    return true if key.blank? || key.length == MASTER_KEY_LENGTH

    # Report the length, never the value.
    fail_with("RAILS_MASTER_KEY must be exactly #{MASTER_KEY_LENGTH} characters " \
              "(Rails checks length, not hex) — this one is #{key.length}. " \
              "A 128-character value is SECRET_KEY_BASE; do not substitute it.")
    false
  end

  # For a self-deploy, Conductor's own running container already holds its
  # secrets in ENV (RAILS_MASTER_KEY, DATABASE_PASSWORD, the AR keys, SES, …),
  # which the kamal subprocess inherits and the committed .kamal/secrets resolves.
  def resolvable_from_conductor_env?(key)
    return true if ENV[key].present?
    return true if key == "RAILS_MASTER_KEY" && ENV["RAILS_MASTER_KEY"].present?

    # The committed .kamal/secrets (which a self-deploy reuses) may alias this key
    # to another env var — e.g. the Postgres accessory seed `POSTGRES_PASSWORD=$DATABASE_PASSWORD`.
    # Follow that indirection: the key resolves if its referenced env var is present.
    ref = committed_secret_reference(key)
    ref.present? && ENV[ref].present?
  end

  # Parse the committed .kamal/secrets for `KEY=$REF` (or `${REF}`) and return the
  # bare referenced env var name, or nil. Only the `$VAR` indirection form is an
  # env alias; `$(cat …)` materialization and literals are not.
  def committed_secret_reference(key)
    path = File.join(checkout_dir, ".kamal", "secrets")
    return nil unless File.exist?(path)

    File.readlines(path).each do |line|
      m = line.match(/\A\s*#{Regexp.escape(key)}\s*=\s*\$\{?([A-Z][A-Z0-9_]+)\}?\s*\z/)
      return m[1] if m
    end
    nil
  end

  # Secret keys the app's deploy.yml references — bare UPPER_SNAKE list items
  # under registry.password and env.secret. Each must be present in the app's
  # EnvVariables, since KamalEnvWriter builds .kamal/secrets from them.
  def required_secrets
    path = File.join(checkout_dir, "config", "deploy.yml")
    return [] unless File.exist?(path)

    File.readlines(path).filter_map { |line| line[/\A\s*-\s*([A-Z][A-Z0-9_]+)\s*\z/, 1] }.uniq
  end

  # For a self-deploy, the repo's committed .kamal/secrets reads the master key
  # via `$(cat config/master.key)`, but a server-side clone omits the gitignored
  # file. Conductor's own container already holds RAILS_MASTER_KEY (its own
  # deploy.yml injects it), so write the file from that env var — no need to enter
  # it as an app env var. Only done for self-managed apps (where Conductor's key
  # IS the app's key); other apps must supply their own.
  def materialize_master_key
    return unless app.self_managed?

    key = ENV["RAILS_MASTER_KEY"]
    return if key.blank?

    path = File.join(checkout_dir, "config", "master.key")
    return if File.exist?(path)

    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, key)
    File.chmod(0o600, path)
    log "Materialized config/master.key from Conductor's RAILS_MASTER_KEY for the self-deploy."
  end

  # Record the checked-out HEAD as the deployment's commit. Kamal uses this same
  # sha as the release version (injected into the container as KAMAL_VERSION), so
  # recording it lets SelfDeployReconciler match a stranded self-deploy to the
  # release that actually booted.
  def record_commit_sha
    result = @shell.run("git", "-C", checkout_dir, "rev-parse", "HEAD")
    sha = result.output.to_s.strip
    deployment.update!(commit_sha: sha) if result.success? && sha.present?
  rescue StandardError
    nil
  end

  # A self-managed deploy replaces THIS Conductor container, killing this job
  # mid-`kamal deploy`. Explain that in the log so a truncated deploy log isn't
  # mistaken for a crash; the new release reconciles the status on boot.
  def note_self_deploy
    log "Self-managed deploy: kamal will replace this Conductor container. If this " \
        "job is terminated during the release swap, the deployment is reconciled " \
        "when the new release boots (commit #{deployment.commit_sha.to_s[0, 12]})."
  end

  # Idempotent: clone on first deploy, otherwise fetch + hard-reset. Resets to the
  # exact pinned @target_sha (deterministic) when we resolved one, else to the branch
  # head (legacy fallback). Resetting to a specific sha the fetch didn't deliver fails
  # loud — which is correct: better a failed deploy than a silently stale image.
  # Say where this image is about to be built, from the checkout rather than from
  # policy. Conductor builds on the control machine and pushes; the target pulls.
  # But that is the DEFAULT, expressed as the absence of `builder.remote`, and two
  # apps in this fleet legitimately set it — one of them builds on a box that also
  # serves production traffic, which is a fact worth seeing in the deploy log
  # rather than discovering from a CPU graph. Read-only, and never fatal: failing
  # a deploy over a log line would be absurd.
  def record_build_location
    config = Dir[File.join(checkout_dir, "config", "deploy*.yml")].min
    return unless config

    remote = File.read(config)[/^\s*remote:\s*(\S+)/, 1]
    host = remote.presence || CONTROL_MACHINE
    log(remote ? "build host: REMOTE #{remote} — this app builds on another machine, and if that " \
                 "machine also serves traffic the build competes with it"
               : "build host: control machine (built here, pushed to the registry; the target pulls)")
    # Persist the observation so it can be reported and warned on BEFORE the next
    # deploy, rather than discovered in a log after the build has already started.
    app.update_columns(build_host: host) if app.build_host != host
  rescue StandardError => e
    log("build host: could not be read from the checkout (#{e.class})")
  end

  def sync_repo_command
    branch = app.branch.presence || "main"
    target = @target_sha.presence || "origin/#{branch}"
    script = if Dir.exist?(File.join(checkout_dir, ".git"))
      "cd #{esc(checkout_dir)} && git fetch origin && git checkout #{esc(branch)} && git reset --hard #{esc(target)}"
    else
      "git clone --branch #{esc(branch)} #{esc(repo_url)} #{esc(checkout_dir)} && " \
        "git -C #{esc(checkout_dir)} reset --hard #{esc(target)}"
    end
    ["bash", "-lc", script]
  end

  # The authoritative branch tip at trigger time, read straight from the remote.
  # Used to pin the checkout deterministically and to assert the build shipped it.
  def resolve_target_sha
    branch = app.branch.presence || "main"
    result = @shell.run("bash", "-lc",
                        "git ls-remote #{esc(repo_url)} #{esc("refs/heads/#{branch}")}", env: git_env)
    return nil unless result.success?
    # Extract the sha, ignoring any credential-helper / progress noise the combined
    # stdout+stderr stream may carry ahead of it.
    result.output.to_s[/\b[0-9a-f]{40}\b/]
  rescue StandardError
    nil
  end

  # Surface a drift between the pinned target and what actually synced. ADVISORY
  # ONLY — logs loudly but never blocks the deploy. (A hard fail here caused a
  # self-deploy retry loop, since the deploy job runs inside the container being
  # replaced.) The real guarantee is verifying the running image SHA after the
  # deploy; this just makes drift visible in the log. Sha is regex-extracted so
  # stream noise in `rev-parse` output can't cause a false signal.
  def verify_synced_head
    return true if @target_sha.blank?
    result = @shell.run("git", "-C", checkout_dir, "rev-parse", "HEAD")
    head = result.output.to_s[/\b[0-9a-f]{40}\b/]
    unless result.success? && head == @target_sha
      log "WARNING: checkout drift — synced #{head.to_s[0, 12].presence || '(unknown)'} " \
          "but pinned target is #{@target_sha[0, 12]}. Proceeding; verify the running image SHA."
    end
    true
  end

  # Clone auth precedence: GitHub App installation token (https) → deploy key
  # (ssh) → plain url.
  def repo_url
    if @clone_token && app.github_repo
      "https://x-access-token@github.com/#{app.github_repo}.git"
    elsif app.deploy_key
      DeployKey.ssh_url(app.repository_url)
    else
      app.repository_url
    end
  end

  def git_env
    if @askpass_file
      { "GIT_ASKPASS" => @askpass_file, "GIT_TERMINAL_PROMPT" => "0" }
    elsif @deploy_key_file
      { "GIT_SSH_COMMAND" => "ssh -i #{@deploy_key_file} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new" }
    else
      {}
    end
  end

  # A short-lived GitHub App installation token for cloning, or nil.
  def resolve_clone_token
    return nil unless app.github_repo

    gh = GithubApp.from_config
    return nil unless gh

    gh.clone_token_for(app.github_repo)
  rescue GithubApp::Error => e
    log "GitHub App token unavailable (#{e.message}); falling back to deploy key / plain url"
    nil
  end

  # Askpass script feeds the token as the git password (never in a logged command).
  def write_askpass(token)
    path = File.join(workspace, ".askpass_#{app.slug}")
    File.write(path, "#!/bin/sh\nexec echo #{Shellwords.escape(token)}\n")
    File.chmod(0o700, path)
    path
  end

  # Materialize the repo deploy key (separate from the target-host ssh key).
  def write_deploy_key
    key = app.deploy_key&.private_key
    return nil if key.blank?

    path = File.join(workspace, ".deploykey_#{app.slug}")
    File.write(path, key.end_with?("\n") ? key : "#{key}\n")
    File.chmod(0o600, path)
    path
  end

  # Proxy-less (host-Caddy) apps publish a FIXED host port, so kamal's normal roll
  # — boot the new container ALONGSIDE the old, health-check it, then retire the
  # old — can't bind: the old container still holds the port and `docker run` dies
  # with "port is already allocated" (the deploy #182 failure). Build and push
  # while the incumbent still serves, then stop it only for the prebuilt-image
  # boot. A failed build must never turn into an outage. Kamal-proxy apps keep
  # their normal zero-downtime roll.
  #
  # Advisory by design: `kamal app stop` is idempotent (a no-op on a first deploy),
  # skipped for self-managed apps (which would kill their own deploy job), and we
  # never block the deploy on it — a genuine conflict still surfaces at boot.
  # Forced invariant: a host-Caddy box runs NO kamal-proxy. kamal-proxy would
  # seize :80/:443 and collide with the host Caddy fronting the shared box
  # (a caddy-edge app did exactly this once). On a caddy-edge target the config
  # MUST turn kamal-proxy off EXPLICITLY — merely omitting the `proxy:` block is
  # not enough, kamal 2.x still boots it. Assert a literal `proxy: false` is present
  # in config/deploy*.yml (one app nests it inside a Caddy-mode ERB branch, another
  # sets it flat — both satisfy the grep). If absent, refuse rather than let the
  # collision reach the box. Non-caddy targets (or an undetected edge) are exempt.
  def verify_proxy_off_on_caddy_edge
    return true unless deploy_server&.edge_type == "caddy"

    configs = Dir.glob(File.join(checkout_dir, "config", "deploy*.yml"))
    return true if configs.any? { |f| File.read(f).match?(/^\s*proxy:\s*false\b/) }

    fail_with("Refusing to deploy #{app.name} to #{deploy_server.name}: it fronts with host Caddy, so " \
              "kamal-proxy must be OFF, but no explicit `proxy: false` is set in config/deploy*.yml. " \
              "`kamal deploy` would boot kamal-proxy on :80/:443 and collide with host Caddy. Add a " \
              "role-level `proxy: false` (see any caddy-edge app in this fleet).")
    false
  end

  def caddy_cutover
    return nil unless deploy_server&.edge_type == "caddy" && app.domain.present?

    @caddy_cutover ||= CaddyCutover.new(
      app,
      client: CaddyClient.new(deploy_server, ssh_connection: ssh)
    )
  end

  def reconcile_caddy_edge
    return true unless caddy_cutover

    report = caddy_cutover.reconcile!
    log "Caddy routes reconciled: #{report[:domains].join(', ')} -> #{report[:upstream]}"
    true
  rescue CaddyCutover::Error => e
    fail_with("Caddy edge reconciliation failed: #{e.message}")
    false
  end

  def prepare_caddy_edge
    caddy_cutover&.prepare!
    true
  rescue CaddyCutover::Error => e
    fail_with("Caddy edge preflight failed: #{e.message}")
    false
  end

  def stop_prior_container_if_fixed_port
    return true if app.self_managed?
    return true unless fixed_port_app?

    log "=== proxy-less (host-Caddy) fixed-port app: stopping prior container so the port frees before boot ==="
    return false unless stop_native_port_owner

    result = @shell.run("bash", "-lc", "#{kamal_bin} #{kamal_gateway.stop}", chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    log "prior-container stop returned exit #{result.exit_code} (advisory; continuing to boot)" unless result.success?
    release_fixed_port
    @stopped_prior = true
    return true if fixed_port_free?

    fail_with("Fixed port #{fixed_host_port} is still in use after releasing #{app.name}'s native units and containers. " \
              "Refusing to boot or stop an unidentified process.")
    recover_after_stop_first
    false
  end

  # A first Kamal adoption can find the fixed port owned by the app's legacy
  # systemd service rather than a container. The unit names are the native
  # deploy contract (`<slug>-server.service` + socket), so stop only those exact
  # app-owned units. Keep the snapshot for fail-safe recovery below.
  def stop_native_port_owner
    @stopped_native_units = active_native_units
    return true if @stopped_native_units.empty?

    units = Shellwords.join(@stopped_native_units)
    log "fixed port #{fixed_host_port} is served by legacy native units; disabling them for Kamal adoption"
    @stopped_prior = true
    result = ssh.execute_with_status("systemctl --user disable --now #{units}")
    return true if result[:success]

    fail_with("Could not stop #{app.name}'s native units before Kamal adoption")
    recover_after_stop_first
    false
  rescue StandardError => e
    fail_with("Could not inspect #{app.name}'s native units: #{e.message}")
    recover_after_stop_first
    false
  end

  def active_native_units
    return [] if ssh.nil?

    candidates = [ "#{app.slug}-server.service", "#{app.slug}-server.socket" ]
    checks = candidates.map do |unit|
      escaped = Shellwords.escape(unit)
      %(if systemctl --user is-active --quiet #{escaped}; then printf '%s\\n' #{escaped}; fi)
    end
    result = ssh.execute_with_status(checks.join("; "))
    return [] unless result[:success]

    result[:output].to_s.lines.map(&:strip) & candidates
  end

  def fixed_port_free?
    return false if fixed_host_port.blank? || ssh.nil?

    result = ssh.execute_with_status("ss -ltnH 'sport = :#{Integer(fixed_host_port)}'")
    result[:success] && result[:output].to_s.strip.empty?
  rescue ArgumentError, TypeError
    false
  end

  # A deploy that fails leaves a container behind, and nothing ever removed them:
  # One app accumulated ELEVEN — three never-started plus four kamal `_replaced_`
  # leftovers — and detecting them was not a solution. The deploy that creates the
  # junk is the thing that should clear it, and it knows which containers are its own.
  #
  # Only after a SUCCESSFUL deploy. After a failure those leftovers are the evidence
  # an operator needs to diagnose it, and removing them would be destroying the
  # scene. Only never-started and superseded-by-rename containers, never a running
  # one, and never another app's.
  #
  # Removing a stopped container costs no rollback: `kamal rollback <version>` boots
  # from the retained IMAGE, and every release image was still present when
  # its eleven containers were removed.
  def prune_dead_boot_artifacts
    return unless fixed_port_app? || app.kamal?
    return if ssh.nil?

    listing = ssh.execute_with_status(%(docker ps -a --format '{{.ID}}|{{.Names}}|{{.State}}'))
    return unless listing[:success]

    listing[:output].to_s.lines.map(&:strip).reject(&:empty?).each do |line|
      id, name, state = line.split("|")
      next if id.blank? || state.to_s.casecmp?("running")
      next unless state.to_s.casecmp?("created") || name.to_s.include?("_replaced_")
      next unless owns_container?(name, nil)

      log "pruning dead boot artifact #{name} (#{id}, #{state}) — it holds no traffic and rollback boots from the image"
      ssh.execute_with_status("docker rm #{id}")
    end
  rescue StandardError => e
    # Never fail a successful deploy over cleanup.
    log "prune skipped: #{e.message}"
  end

  # `kamal app stop` matches containers by their CURRENT name — but when the name
  # is already taken kamal RENAMES the incumbent to `<name>_replaced_<hash>` before
  # booting the replacement. A renamed container keeps running and keeps holding
  # the published port, so the stop above matches nothing and the boot still dies
  # with "port is already allocated". Three consecutive deploys failed exactly this
  # way while a `<service>-web-latest_replaced_<hash>` container sat healthy on the port.
  #
  # So free the port by what HOLDS it rather than by what it is called — and only
  # if it belongs to this app. A fixed host port is exclusive, so a STRANGER on it
  # is a real conflict for a human to resolve, never something to kill mid-deploy.
  def release_fixed_port
    port = fixed_host_port
    return if port.blank? || ssh.nil?

    listing = ssh.execute_with_status(
      %(docker ps --filter publish=#{port} --format '{{.ID}}|{{.Names}}|{{.Label "service"}}')
    )
    return unless listing[:success]

    listing[:output].to_s.lines.map(&:strip).reject(&:empty?).each do |line|
      id, name, service = line.split("|")
      next if id.blank?

      if owns_container?(name, service)
        log "port #{port} still held by #{name} (#{id}) — kamal renamed it, so `app stop` missed it; stopping"
        ssh.execute_with_status("docker stop -t 30 #{id}")
      else
        log "WARNING: port #{port} is held by #{name} (service=#{service}), which is NOT #{app.name}. " \
            "Leaving it alone — the boot will fail and that is the honest outcome."
      end
    end
  end

  # The exclusive host port this app publishes when it runs proxy-less.
  def fixed_host_port = app.published_port

  # Kamal names containers `<service>-web-<version>`, so the fallback must anchor
  # on the role separator. A bare `start_with?` let an app whose service is a
  # PREFIX of another's (`calm` vs `myapp`) claim a stranger's container and
  # stop it — the precise opposite of what this step is for.
  def owns_container?(name, service)
    candidates = ([ app.resource_key ] + Array(app.kamal_service_candidates)).compact.map(&:to_s)
    return true if service.present? && candidates.include?(service.to_s)
    return false if service.present? # labelled, and the label is not ours

    candidates.any? { |c| name.to_s == c || name.to_s.start_with?("#{c}-") }
  end

  def ssh
    @ssh ||= @injected_ssh || (deploy_server && SshConnection.new(deploy_server))
  end

  # Does this app publish a FIXED host port that the old container still holds
  # when the new one boots?
  #
  # This used to be detected by a CADDY_PUBLISH_PORT env var — a naming
  # convention and a second source of truth. Apps that publish a fixed port
  # any other way (straight `publish:` in deploy.yml) skipped the stop-first step
  # and failed EVERY redeploy with "Bind for 0.0.0.0:<port> failed: port is
  # already allocated". That is what kept the fixed-port apps failing.
  #
  # The structural signal is the edge: on a host-Caddy box kamal-proxy is off, so
  # the container must publish a fixed port for Caddy to reach it. No proxy means
  # nothing can hold two releases at once.
  def fixed_port_app?
    deploy_server&.edge_type == "caddy"
  end

  # Safety net for the stop-first path. Stopping the old container BEFORE boot means
  # a failed deploy leaves the app with NOTHING running — strictly worse than a
  # normal failed roll where the old container keeps serving (this is what briefly
  # took an app down: the image was fine, a lock race just failed the run). So on
  # a post-stop failure, best-effort `kamal app boot` to bring the app back up
  # (boots the latest good version kamal retains). Only fires when we actually
  # stopped first; never raises — recovery must not mask the original failure.
  def recover_after_stop_first
    return unless @stopped_prior

    if @stopped_native_units.present?
      restore_native_units
      return
    end

    log "=== deploy failed after stop-first — best-effort rebooting so the app isn't left down ==="
    @shell.run("bash", "-lc", "#{kamal_bin} #{kamal_gateway.boot}", chdir: checkout_dir, env: deploy_env) { |line| log(line) }
  rescue StandardError => e
    log "recovery reboot failed (#{e.message}); manual `kamal app boot` may be needed"
  end

  def restore_native_units
    units = Shellwords.join(@stopped_native_units)
    path = Shellwords.escape(app.health_check_path.presence || "/up")
    port = Integer(fixed_host_port)
    command = "systemctl --user daemon-reload && " \
              "systemctl --user enable #{units} && " \
              "systemctl --user start #{units} && " \
              "for attempt in 1 2 3 4 5 6 7 8 9 10; do " \
              "curl -fsS http://127.0.0.1:#{port}#{path} >/dev/null && exit 0; sleep 1; done; exit 1"
    log "=== deploy failed after native handoff — restoring the prior native service and verifying health ==="
    result = ssh.execute_with_status(command)
    log "native recovery failed; manual systemd recovery is required" unless result[:success]
  end

  # Runs `kamal deploy`, recovering from a stale deploy lock. Kamal takes a global
  # per-service "Automatic deploy lock" and releases it in an ensure; a process
  # killed mid-run (e.g. a self-deploy where kamal stops THIS container) never
  # releases it, so the next deploy fails with "Deploy lock found".
  #
  # CAUTION — this used to release-and-retry for EVERY app, justified by the
  # unique partial index idx_one_active_deploy_per_app "guaranteeing" at most one
  # in-flight deploy per app. That premise is false: the index constrains
  # Deployment ROWS, and a deploy can happen without creating one — CI
  # (.github/workflows/deploy.yml) does exactly that, as does a laptop running
  # bin/kamal. So a lock may belong to a genuinely concurrent deploy, and blindly
  # releasing it would let two rolls run against one host at once.
  #
  # CI only ever deploys the self-managed app (Conductor itself), and those no
  # longer deploy in-product at all — so restricting reclamation to
  # non-self-managed apps removes exactly the case where a live competing
  # deployer can exist, while keeping recovery for the ordinary killed-job case.
  def build_before_fixed_port_stop
    return true unless fixed_port_app?
    return produce_image_elsewhere if elsewhere_build?

    log "=== building and pushing release before stopping the fixed-port incumbent ==="
    result = @shell.run(*kamal_build_command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    return true if result.success?

    fail_with("kamal build push failed (exit #{result.exit_code}) — incumbent left running")
    false
  end

  # Only when the app has explicitly opted in. Nil ci_build_workflow means every
  # existing app keeps the exact path it has today — a build-venue change is not
  # something to acquire by upgrading.
  def elsewhere_build? = app.try(:ci_build_workflow).present? && @target_sha.present?

  # Produce the image without using this machine: reuse what is already built, or
  # build it in CI. A refusal here is never fatal — it falls back to building
  # locally, which is what would have happened anyway.
  def produce_image_elsewhere
    existing = RegistryImage.new(app).check(@target_sha)
    if existing.exists?
      log "=== image already built for #{@target_sha[0, 7]} (#{existing.detail}) — skipping the build ==="
      record_build_venue("registry-cache")
      return true
    end

    log "=== building #{@target_sha[0, 7]} on CI (this machine stays out of it) ==="
    outcome = GithubActionsBuild.new(app).build!(@target_sha)
    if outcome.ok?
      log "CI build succeeded#{" — #{outcome.run_url}" if outcome.run_url}"
      record_build_venue("ci:github-actions")
      return true
    end

    # A RED BUILD STOPS HERE. Rebuilding a broken commit on another machine reaches
    # the same red, slower, having spent the venue the fallback exists to protect.
    if outcome.status == :build_failed
      fail_with("CI build failed for #{@target_sha[0, 7]} — the commit is broken, not the venue" \
                "#{" (#{outcome.run_url})" if outcome.run_url}")
      return false
    end

    log "CI could not take this build (#{outcome.reason}: #{outcome.detail}) — building here instead"
    result = @shell.run(*kamal_build_command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    return true if result.success?

    fail_with("kamal build push failed (exit #{result.exit_code}) — incumbent left running")
    false
  end

  def record_build_venue(venue)
    app.update_columns(build_host: venue) if app.build_host != venue
  end

  def run_kamal_deploy(prebuilt: false)
    operation = prebuilt ? "kamal deploy --skip-push" : "kamal deploy"
    command = kamal_command(prebuilt: prebuilt)
    log "Running: #{operation}"
    result = @shell.run(*command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    return true if result.success?

    if result.output.to_s.include?("Deploy lock found") && reclaimable_lock?
      log "Stale kamal deploy lock detected (a prior deploy was killed mid-run). Releasing and retrying once."
      @shell.run(*kamal_lock_release_command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
      result = @shell.run(*command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
      return true if result.success?
    end

    fail_with("kamal deploy failed (exit #{result.exit_code})")
    false
  end

  # `kamal rollback <version>` — boots the image already tagged <version> on the
  # host. Same stale-lock recovery as deploy (a killed run can strand the lock).
  def run_kamal_rollback(version)
    log "Running: kamal rollback #{version}"
    result = @shell.run(*kamal_rollback_command(version), chdir: checkout_dir, env: deploy_env) { |line| log(line) }

    if !result.success? && result.output.to_s.include?("Deploy lock found") && reclaimable_lock?
      log "Stale kamal lock detected (a prior deploy was killed mid-run). Releasing and retrying once."
      @shell.run(*kamal_lock_release_command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
      result = @shell.run(*kamal_rollback_command(version), chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    end

    unless result.success?
      fail_with("kamal rollback failed (exit #{result.exit_code}) — the target version's image may no longer be retained on the host")
      return false
    end

    return true if rollback_version_running?(version)

    fail_with("kamal rollback exited 0, but release #{version} is not running — refusing a false success")
    false
  end

  # `kamal deploy` from the checkout; prefer the bundled binstub.
  def kamal_command(prebuilt: false)
    operation = prebuilt ? kamal_gateway.deploy_prebuilt : kamal_gateway.deploy
    ["bash", "-lc", "#{kamal_bin} #{operation}"]
  end

  def kamal_build_command = [ "bash", "-lc", "#{kamal_bin} #{kamal_gateway.build_release}" ]

  def kamal_rollback_command(version)
    ["bash", "-lc", "#{kamal_bin} #{kamal_gateway.rollback(version)}"]
  end

  def rollback_version_running?(version)
    command = [ "bash", "-lc", "#{kamal_bin} #{kamal_gateway.exec_live("true", version: version)}" ]
    result = @shell.run(*command, chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    return true if result.success?

    log "rollback postcondition failed: release #{version} could not be reused"
    false
  rescue StandardError => e
    log "rollback postcondition failed: #{e.message}"
    false
  end

  # A lock is only ours to reclaim when no other deployer can hold it. CI deploys
  # the self-managed app, so for that app a lock may be LIVE — never grab it.
  def reclaimable_lock?
    return true unless app.self_managed?
    return true if @allow_self_deploy

    log "Deploy lock found for a self-managed app — NOT releasing: CI may hold it. " \
        "If CI is idle, release it by hand (bin/kamal lock release -d production)."
    false
  end

  def kamal_lock_release_command
    ["bash", "-lc", "#{kamal_bin} #{kamal_gateway.release_lock}"]
  end

  # Gated migrations (roadmap slot 24). The image entrypoint runs db:prepare
  # silently on boot; run db:migrate explicitly in the just-deployed container and
  # then abort_if_pending as a FAIL-LOUD check — so a failed or incomplete
  # migration fails the deploy instead of leaving the DB lagging the code (the
  # recurring prod-500 root cause). Idempotent: a no-op when already migrated.
  def run_gated_migrations
    log "=== gated migrations: bin/rails db:migrate ==="
    migrate = @shell.run(*kamal_app_exec("bin/rails db:migrate"), chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    unless migrate.success?
      fail_with("db:migrate failed (exit #{migrate.exit_code}) — deploy halted before marking success")
      return false
    end

    check = @shell.run(*kamal_app_exec("bin/rails db:abort_if_pending_migrations"), chdir: checkout_dir, env: deploy_env) { |line| log(line) }
    unless check.success?
      fail_with("pending migrations remain after deploy — schema is behind the code")
      return false
    end
    true
  end

  # Seed writer (roadmap slot 08). One-shot: when the operator/agent has requested
  # seeds (app.seed_on_next_deploy), run db:seed in the just-deployed container and
  # RECORD a SeedApplication with real evidence — the db/seeds.rb digest, the run
  # output, and the true exit status. This is what makes the preflight "seeds" gate
  # meaningful (something finally writes the ledger). A failed seed fails the deploy
  # (consistent with the gate). The flag is cleared whether it succeeds or fails so
  # a stuck request can't loop.
  def run_seeds_if_requested
    return true unless app.seed_on_next_deploy?

    log "=== running seeds (requested): bin/rails db:seed ==="
    buffer = +""
    result = @shell.run(*kamal_app_exec("bin/rails db:seed"), chdir: checkout_dir, env: deploy_env) do |line|
      buffer << line << "\n"
      log(line)
    end

    app.seed_applications.create!(
      status:     result.success? ? "succeeded" : "failed",
      digest:     seeds_digest,
      applied_at: Time.current,
      output:     buffer.last(4000)
    )
    app.update_columns(seed_on_next_deploy: false)

    return true if result.success?

    fail_with("db:seed failed (exit #{result.exit_code}) — deploy halted; seed run recorded as failed")
    false
  end

  # SHA256 of the committed db/seeds.rb (evidence of WHICH seeds ran), or nil.
  def seeds_digest
    path = File.join(checkout_dir, "db", "seeds.rb")
    File.exist?(path) ? Digest::SHA256.hexdigest(File.read(path)) : nil
  end

  # Run a command inside the just-deployed container (kamal app exec --reuse),
  # honouring the destination for self-describing apps.
  def kamal_app_exec(command)
    ["bash", "-lc", "#{kamal_bin} #{kamal_gateway.exec_live(command)}"]
  end

  def kamal_gateway
    @kamal_gateway ||= KamalGateway.new(destination: (KamalConfig::DESTINATION if app.self_describing?))
  end

  # How to invoke Kamal from Conductor's own container (the control machine).
  #
  # Two things make the obvious answers wrong:
  #
  #   - Bare `kamal` is not on PATH. Every command here runs through `bash -lc`,
  #     and a login shell re-sets PATH from /etc/profile — dropping the bundle's
  #     bin dir, which is where the binstub lives
  #     (/usr/local/bundle/ruby/<abi>/bin/kamal). The gem IS installed; only the
  #     lookup fails, which reads like "kamal is missing" but isn't.
  #   - The target app's `./bin/kamal` (Rails 8 apps ship one) resolves against
  #     THAT app's Gemfile, whose gems were never installed in the checkout —
  #     Conductor deploys the app, it doesn't bundle it.
  #
  # So: run Conductor's own bundled Kamal, pinning BUNDLE_GEMFILE because the
  # working directory is the target app's checkout.
  def kamal_bin
    "BUNDLE_GEMFILE=#{esc(conductor_gemfile)} bundle exec kamal"
  end

  # Conductor's Gemfile — the bundle that actually has Kamal in it.
  def conductor_gemfile
    ENV["CONDUCTOR_GEMFILE"].presence || Rails.root.join("Gemfile").to_s
  end

  # Conductor's env vars become Kamal's process env (deploy.yml ERB reads e.g.
  # DEPLOY_SERVER_IP / KAMAL_REGISTRY_USERNAME), plus the SSH key for net-ssh.
  def deploy_env
    env = app.env_variables.each_with_object({}) { |v, h| h[v.key] = v.value }
    # Some legacy app repos use this ERB selector to choose their Caddy branch.
    # Keep that grammar at the adapter boundary, derived from the canonical
    # App#port, so the stored env value can neither drift nor follow an app onto
    # a kamal-proxy server and accidentally disable its proxy.
    if deploy_server.edge_type == "caddy" && app.published_port.present?
      env["CADDY_PUBLISH_PORT"] = app.published_port.to_s
    else
      env.delete("CADDY_PUBLISH_PORT")
    end
    env["DEPLOY_SERVER_IP"] ||= deploy_server.ip_address
    env["DEPLOY_SSH_USER"]  ||= deploy_server.ssh_user_or_default
    env["APP_HOST"]         ||= app.domain if app.domain.present?
    env["SSH_KEYS"] = @key_file if @key_file # consumed by deploy.yml ssh.keys
    if @ssh_home
      # Cross-host roll fix. The docker connhelper's `ssh` binary reads the real
      # passwd-home ~/.ssh (ignores $HOME), which is why build+push work. But
      # kamal's container roll uses SSHKit → Net::SSH (pure Ruby), which resolves
      # ~/.ssh/config from the child's $HOME. If $HOME differs from the dir
      # setup_ssh_home wrote the IdentityFile stanza into, Net::SSH finds no key
      # and falls back to password auth — which dies ENOTTY in the non-interactive
      # job (build succeeds, roll fails, identically). Pin HOME to that dir so
      # Net::SSH reads the same config the ssh binary does.
      env["HOME"] = File.dirname(@ssh_home)
      # Build on the target's docker daemon over SSH (avoids mounting docker.sock
      # into this container). The host key + identity live in the real ~/.ssh that
      # docker's ssh connhelper reads — NOT an env $HOME, which ssh ignores (it
      # resolves ~ from the passwd database, not $HOME).
      env["DOCKER_HOST"] = "ssh://#{deploy_server.ssh_user_or_default}@#{deploy_server.ip_address}"
      # Isolate buildx state PER TARGET HOST. Kamal's builder name is a constant
      # (`kamal-local-docker-container`), but its endpoint is baked in from the
      # DOCKER_HOST of whichever deploy created it. With one shared buildx config,
      # app A's deploy inherits app B's builder and tries to build on B's server:
      # One deploy failed dialling ANOTHER app's host as root, using an
      # identity for an app it has nothing to do with. Per-target state means a
      # record made for one host can never be handed to another.
      env["BUILDX_CONFIG"] = buildx_config_dir
    end
    env
  end

  def buildx_config_dir
    dir = File.join(workspace, ".buildx", "server-#{deploy_server.id}")
    FileUtils.mkdir_p(dir)
    dir
  end

  # The ssh dir that OpenSSH actually reads. ssh resolves `~` from the passwd
  # database (getpwuid), ignoring $HOME, so we must write into the real home —
  # not an isolated one. Overridable in tests so they never touch the real ~/.ssh.
  def ssh_dir
    File.join(ENV.fetch("CONDUCTOR_SSH_HOME") { Dir.home }, ".ssh")
  end

  # Prepare the real ~/.ssh so `docker --host ssh://…` (buildx, over SSH) and
  # `kamal` (net-ssh) can both reach the target: a per-app identity key, a Host
  # stanza pointing at it, and the pre-trusted host key. Returns the dir.
  def setup_ssh_home
    return nil unless @key_file

    ssh = ssh_dir
    FileUtils.mkdir_p(ssh)
    File.chmod(0o700, ssh)

    # Per-RUN identity, not per-app. Two deploys of the same app overlap easily —
    # a build takes minutes — and with a shared `conductor_<slug>` path the first
    # run's cleanup deletes the key the second run is still using, mid-deploy. The
    # symptom is brutal to read: build and push succeed (key still present), then
    # the container roll falls back to password auth and dies with ENOTTY.
    @managed_identity = File.join(ssh, "conductor_#{app.slug}_#{deployment.id}")
    FileUtils.cp(@key_file, @managed_identity)
    File.chmod(0o600, @managed_identity)

    known_hosts = File.join(ssh, "known_hosts")
    write_ssh_config_block(File.join(ssh, "config"), @managed_identity, known_hosts)
    seed_known_hosts(known_hosts)
    ssh
  end

  # Idempotently upsert a marked Host stanza in ~/.ssh/config for this app's
  # target, so repeat deploys don't accumulate duplicate blocks.
  def write_ssh_config_block(config_path, identity, known_hosts)
    b = ssh_config_marker_begin
    e = ssh_config_marker_end
    block = <<~CFG
      #{b}
      Host #{deploy_server.ip_address}
        User #{deploy_server.ssh_user_or_default}
        IdentityFile #{identity}
        IdentitiesOnly yes
        StrictHostKeyChecking accept-new
        UserKnownHostsFile #{known_hosts}
      #{e}
    CFG
    # Concurrent deploys of different apps share this one ~/.ssh/config. Without a
    # lock, two runs that both read before either writes each drop the other's live
    # stanza (the last writer wins). Serialize the whole read-modify-write.
    with_ssh_config_lock(config_path) do
      existing = File.exist?(config_path) ? File.read(config_path) : ""
      # Drop this run's block if it somehow exists, plus any stale per-app block from
      # the pre-#{deployment.id} scheme, so an old dangling IdentityFile can't win.
      existing = strip_ssh_config_block(existing, b, e)
      existing = strip_ssh_config_block(existing, "# >>> conductor #{app.slug} >>>", "# <<< conductor #{app.slug} <<<")
      File.write(config_path, existing + block)
      File.chmod(0o600, config_path)
    end
  end

  # Exclusive flock over the shared ~/.ssh/config so concurrent deploys never
  # interleave their read-modify-write and clobber each other's stanza.
  def with_ssh_config_lock(config_path)
    lock_path = "#{config_path}.conductor.lock"
    File.open(lock_path, File::RDWR | File::CREAT, 0o600) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def strip_ssh_config_block(text, marker_begin, marker_end)
    text.gsub(/#{Regexp.escape(marker_begin)}.*?#{Regexp.escape(marker_end)}\n/m, "")
  end

  # Markers are per-RUN so a concurrent deploy of the same app removes only its own
  # stanza — and so cleanup can take the stanza away with the key it points at.
  def ssh_config_marker_begin = "# >>> conductor #{app.slug} run #{deployment.id} >>>"
  def ssh_config_marker_end   = "# <<< conductor #{app.slug} run #{deployment.id} <<<"

  # Pre-trust the target's SSH host key. The build runs on the target's docker
  # daemon over SSH (DOCKER_HOST=ssh://…), and docker's buildx connection — like
  # Kamal's net-ssh — verifies the host key but does NOT honor `accept-new` on
  # first contact, so a first-ever deploy dies with "Host key verification failed".
  # Seed it into the real ~/.ssh/known_hosts (skip if already trusted).
  def seed_known_hosts(path)
    ip = deploy_server.ip_address
    @shell.run("bash", "-lc",
      "touch #{esc(path)}; ssh-keygen -F #{esc(ip)} -f #{esc(path)} >/dev/null 2>&1 || " \
      "ssh-keyscan -t rsa,ecdsa,ed25519 #{esc(ip)} 2>/dev/null >> #{esc(path)}; true")
  end

  # Diagnostics for the build-over-SSH host-key path. The build runs on the
  # target daemon via DOCKER_HOST=ssh://… and buildx's connection must trust the
  # host key. This probes the EXACT connection (same env as `kamal deploy`) so a
  # failure here localizes the problem to the docker-over-ssh handshake rather
  # than buildx internals. Never fails the deploy.
  def log_ssh_diagnostics
    return unless @ssh_home

    user = esc(deploy_server.ssh_user_or_default)
    host = esc(deploy_server.ip_address)
    script = <<~SH
      echo "ssh probe:"; ssh -o BatchMode=yes -o ConnectTimeout=8 #{user}@#{host} 'echo ssh-ok' 2>&1 | tail -2
      echo "docker-over-ssh probe:"; docker version --format 'server={{.Server.Version}}' 2>&1 | tail -2
    SH
    log "Running: SSH/Docker diagnostics"
    @shell.run("bash", "-lc", script, env: deploy_env) { |line| log(line) }
  rescue StandardError => e
    log "diagnostics error: #{e.message}"
  end

  # Write Conductor-managed .kamal/secrets (values from EnvVariables).
  #
  # Self-deploys are special: the repo's committed .kamal/secrets is references
  # only (e.g. `$DATABASE_PASSWORD`, `$(cat config/master.key)`) and those resolve
  # from Conductor's OWN container env (inherited by the kamal subprocess) plus
  # the master.key we just materialized — so we PRESERVE it rather than overwrite,
  # and only KAMAL_REGISTRY_PASSWORD needs to come from an app env var (flows in
  # via deploy_env). For other apps Conductor is the source of truth, so we
  # generate the file from the app's EnvVariables as before.
  def write_secrets_file
    secrets_path = File.join(checkout_dir, ".kamal", "secrets")
    return if app.self_managed? && File.exist?(secrets_path)

    content = KamalEnvWriter.secrets_content(app, server: deploy_server)
    return if content.strip.empty?

    FileUtils.mkdir_p(File.dirname(secrets_path))
    File.write(secrets_path, content)
  end

  # ADR 0001: write the generated self-describing artifact into the checkout — the
  # real config/deploy.production.yml overlay + git-safe .kamal/secrets.production.
  # Secrets resolve from deploy_env (variable substitution), which Conductor injects.
  def write_self_describing_config
    KamalConfig.new(app, target_server: @target_server).files.each do |rel_path, content|
      full = File.join(checkout_dir, rel_path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, content)
      log "Wrote self-describing #{rel_path}"
    end
  end

  # Materialize the target server's private key so Kamal's net-ssh can use it.
  def write_ssh_key
    key = deploy_server.ssh_key&.private_key
    return nil if key.blank?

    path = File.join(workspace, ".ssh_#{app.slug}")
    File.write(path, key.end_with?("\n") ? key : "#{key}\n")
    File.chmod(0o600, path)
    path
  end

  # Remove the materialized secrets. @ssh_home is the real ~/.ssh — never delete
  # it; only this run's identity key and the stanza that names it.
  #
  # The stanza MUST go with the key. Leaving `IdentityFile … / IdentitiesOnly yes`
  # pointing at a deleted file is worse than leaving nothing: ssh then offers no
  # identity at all and falls back to password auth, which in a non-interactive
  # deploy dies with `Errno::ENOTTY` — the error reads like "no key was ever
  # configured" when the truth is "the key was configured, then removed".
  # known_hosts stays: host trust is legitimately durable.
  def cleanup_key
    [ @key_file, @deploy_key_file, @askpass_file, @managed_identity ].compact.each do |f|
      File.delete(f) if File.exist?(f)
    end
    remove_ssh_config_block
  rescue StandardError
    nil
  end

  def remove_ssh_config_block
    return unless @ssh_home

    path = File.join(@ssh_home, "config")
    return unless File.exist?(path)

    # Same shared file, same race on cleanup — take the lock for the read+write.
    with_ssh_config_lock(path) do
      next unless File.exist?(path)

      File.write(path, strip_ssh_config_block(File.read(path), ssh_config_marker_begin, ssh_config_marker_end))
      File.chmod(0o600, path)
    end
  end

  def checkout_dir = File.join(workspace, app.slug)

  def workspace
    ENV.fetch("KAMAL_WORKSPACE", Rails.root.join("tmp", "kamal").to_s)
  end

  def esc(value) = Shellwords.escape(value.to_s)

  # SCRUB BEFORE ANYTHING PERSISTS OR LEAVES THE PROCESS.
  #
  # This method stored a live OAuth client secret in plaintext. kamal prints the
  # full `docker run` line, including inline values for anything the app declared
  # under `env: clear:`, and this captured that stdout verbatim — into the
  # database, into the ActionCable broadcast, and into the Rails log.
  #
  # One redaction point for all three, because three call sites is three chances
  # to add a fourth that forgets.
  def log(message)
    clean = scrubber.scrub(message.to_s)
    deployment.append_log(clean)
    broadcast(clean)
    Rails.logger.info "[KamalDeploy:#{app.slug}] #{clean}"
  end

  def scrubber = @scrubber ||= SecretScrubber.new(app)

  def broadcast(message)
    timestamp = Time.current.strftime("%H:%M:%S")
    ActionCable.server.broadcast(
      "deployment_#{deployment.id}",
      { type: "log", line: "[#{timestamp}] #{message}\n", status: deployment.status }
    )
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
end
