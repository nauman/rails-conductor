# Generates a SELF-DESCRIBING Kamal deploy artifact for an app (ADR 0001).
#
# Kamal 2 does NOT inject env or secrets into config/deploy.yml ERB (Handbook §8.1),
# so real deploy coordinates must be written as literal values — not ENV[...] ||
# placeholder fallbacks whose truth lives only in Conductor's DB. We emit a Kamal
# *destination overlay* so the app's base config is untouched:
#
#   config/deploy.production.yml  — real host/service/proxy/registry + env split
#   .kamal/secrets.production     — git-safe secret POINTERS (localvault / master.key)
#
# Acceptance (ADR 0001): with the repo + an authorized SSH key an operator runs
#   kamal console -d production   /   kamal app logs -d production
# against real prod WITHOUT querying Conductor.
class KamalConfig
  class Error < StandardError; end

  DESTINATION = "production".freeze

  # The fleet's boxes are x86_64, and the control machine may not be — an arm64
  # laptop building without this produces an image the target cannot run. Naming
  # it also makes the build a stated choice rather than a default.
  BUILD_ARCH = "amd64".freeze

  # Keys that ARE the deploy coordinates — represented structurally below, so they
  # don't also leak into env.clear.
  DEPLOY_KEYS = %w[
    KAMAL_SERVICE DEPLOY_SERVER_IP DEPLOY_SSH_USER APP_HOST
    KAMAL_REGISTRY_SERVER KAMAL_REGISTRY_USERNAME KAMAL_REGISTRY_PASSWORD
    CADDY_PUBLISH_PORT
  ].freeze

  attr_reader :app, :vault

  def initialize(app, vault: nil, target_server: nil)
    @app = app
    # localvault vault holding this app's secrets. Convention: key = <slug>.<KEY>.
    @vault = vault.presence || "devops"
    # Where this overlay deploys. Defaults to the app's own server; an app
    # transfer (spec 26) passes a target so the same app deploys to another box.
    @server = target_server || app.server
  end

  # The `service` value MUST equal the `service` LABEL on the running containers,
  # because that is how `kamal app logs / exec / console` finds them.
  #
  #   kamal-deployed — Kamal creates the containers and labels them from this
  #                    value, so it stays the slug. Changing it would rename
  #                    every container AND the proxy route key: a form change.
  #   Conductor-deployed — Conductor labels containers with the stable resource
  #                    key (ADR 0004), so the config must say the same thing or
  #                    the ops CLI is blind to every container we deployed.
  def service_name
    app.kamal? ? app.slug : app.resource_key
  end

  # The real, literal destination overlay (config/deploy.production.yml).
  # Where the image is built, written down instead of defaulted.
  #
  # Conductor builds on the CONTROL MACHINE and pushes to the registry; the target
  # only ever pulls. That was already true, but it was true by ABSENCE — kamal
  # builds locally when no `builder.remote` is set, so a config with no builder
  # block says nothing, and "is this built here or on the box?" had no answer you
  # could read. An agent had to open the file and correctly interpret a section
  # that wasn't there.
  #
  # It matters beyond documentation: a local build keeps the target's CPU and disk
  # out of the deploy, and it is why a fixed-port app can build BEFORE its
  # incumbent is stopped rather than being down for the length of a build.
  def builder_block
    { "arch" => BUILD_ARCH }
  end

  def deploy_overlay_yaml
    overlay = {
      "service" => service_name,
      "image"   => "#{registry_username}/#{app.slug}",
      "servers" => servers_block,
      "ssh"     => { "user" => @server&.ssh_user_or_default || "deploy" },
      "proxy"   => proxy_block,
      "registry" => {
        "server"   => registry_server,
        "username" => registry_username,
        "password" => ["KAMAL_REGISTRY_PASSWORD"]
      },
      "builder" => builder_block,
      "env" => env_block
    }.compact

    header + YAML.dump(overlay).sub(/\A---\n/, "")
  end

  # The git-safe secrets file (.kamal/secrets.production). No raw values — secrets
  # resolve from the ENVIRONMENT (variable substitution), which Conductor injects
  # at deploy time and an operator seeds ONCE for hand use. The header documents
  # the localvault seed so it isn't needed on every command ("seed once").
  def secrets_file
    all_keys = (["KAMAL_REGISTRY_PASSWORD"] + secret_keys).uniq
    all_keys -= ["RAILS_MASTER_KEY"] if app.self_managed?

    header = ["# #{GENERATED} — .kamal/secrets.#{DESTINATION}",
              "# Git-safe: values are NOT here. Conductor injects these at deploy time.",
              "# For hand use (kamal console -d #{DESTINATION}), seed your env ONCE, e.g.:",
              "#   localvault unlock #{vault}"]
    all_keys.each { |k| header << "#   export #{k}=$(localvault get #{app.slug}.#{k} --vault #{vault})" }

    body = all_keys.map { |k| "#{k}=$#{k}" }
    if app.self_managed? && (secret_keys.include?("RAILS_MASTER_KEY") || app.env_hash.key?("RAILS_MASTER_KEY"))
      body << "RAILS_MASTER_KEY=$(cat config/master.key)"
    end

    (header + [""] + body).join("\n") + "\n"
  end

  # Path => contents, for a writer to drop into a checkout (or commit to the repo).
  def files
    {
      "config/deploy.#{DESTINATION}.yml"  => deploy_overlay_yaml,
      ".kamal/secrets.#{DESTINATION}"     => secrets_file
    }
  end

  private

  GENERATED = "Generated by Conductor (self-describing deploy, ADR 0001)".freeze

  def header
    "# #{GENERATED}\n" \
    "# Real deploy coordinates for #{app.name}. Reproducible by hand:\n" \
    "#   kamal console -d #{DESTINATION}   /   kamal app logs -d #{DESTINATION}\n"
  end

  def proxy_block
    return nil unless kamal_proxy_edge?
    return nil if app.domain.blank?

    {
      "ssl" => !!app.ssl_enabled,
      "host" => app.domain,
      "app_port" => app.runtime_port,
      "forward_headers" => true,
      "healthcheck" => {
        "path" => app.health_check_path.presence || "/up",
        "interval" => 2,
        "timeout" => 5
      }
    }
  end

  # Kamal 2 enables the proxy for the primary role when proxy is omitted. Caddy
  # mode must therefore be explicit, and the app must publish only its private
  # loopback port for Caddy to consume. The Docker healthcheck is what Kamal
  # polls when no kamal-proxy is present.
  def servers_block
    hosts = [@server&.ip_address].compact
    return { "web" => hosts } if kamal_proxy_edge?

    host_port = app.published_port
    raise Error, "#{app.name} host-published port is not recorded" if host_port.blank?

    runtime_port = app.runtime_port
    {
      "web" => {
        "hosts" => hosts,
        "proxy" => false,
        "options" => {
          "publish" => "127.0.0.1:#{host_port}:#{runtime_port}",
          "health-cmd" => "curl -f http://127.0.0.1:#{runtime_port}#{app.health_check_path.presence || '/up'} || exit 1",
          "health-interval" => "5s",
          "health-timeout" => "3s",
          "health-retries" => 10,
          "health-start-period" => "10s"
        }
      }
    }
  end

  def kamal_proxy_edge?
    @server&.edge_type != "caddy"
  end

  def env_block
    block = {}
    clear = app.env_variables.visible.reject { |v| DEPLOY_KEYS.include?(v.key) }
                .to_h { |v| [v.key, v.value] }
    block["clear"]  = clear if clear.any?
    block["secret"] = secret_keys if secret_keys.any?
    block.presence
  end

  def secret_keys
    @secret_keys ||= app.deploy_secret_keys(server: @server).reject { |k| DEPLOY_KEYS.include?(k) }.sort
  end

  def registry_server
    # Kamal's default registry is Docker Hub; apps using another registry set
    # KAMAL_REGISTRY_SERVER explicitly. Default here must match Kamal's default.
    app.env_hash["KAMAL_REGISTRY_SERVER"].presence || "docker.io"
  end

  def registry_username
    app.env_hash["KAMAL_REGISTRY_USERNAME"].presence || "REGISTRY_USERNAME"
  end
end
