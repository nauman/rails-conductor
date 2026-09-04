require "shellwords"

# Stands up a dedicated Postgres container on a server over SSH, mirroring
# PostgresClusterClient's docker-over-SSH pattern. PostgresClusterClient runs
# admin SQL inside an *existing* container; this one *creates* the container
# (network + named volume + `docker run`), then waits for it to accept
# connections. Used by DedicatedDbProvisioner (app-transfer spec 26, Slice 2).
class PostgresContainerClient
  class Error < StandardError; end

  DEFAULT_IMAGE = "postgres:16-alpine".freeze
  NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/ # docker object-name charset

  def initialize(server, ssh_connection: nil)
    @server = server
    @ssh = ssh_connection || SshConnection.new(server)
  end

  # Idempotent: creates the network, volume, and container if absent, then
  # blocks until Postgres is ready. Returns a summary hash. No host port is
  # published — the app reaches Postgres over the shared Docker network by
  # container DNS (`<container>:5432`), so there's nothing to allocate.
  def create!(container_name:, volume:, network:, admin_username:, admin_password:,
              image: DEFAULT_IMAGE)
    [ container_name, volume, network ].each { |n| validate_name!(n) }
    validate_name!(admin_username)

    already = container_exists?(container_name)
    unless already
      ensure_network(network)
      ensure_volume(volume)
      run_container(container_name:, volume:, network:, admin_username:, admin_password:, image:)
    end
    wait_ready(container_name, admin_username)

    { "container" => container_name, "action" => already ? "exists" : "created" }
  end

  # The aliases Docker has actually attached, read off the container. Recording an
  # alias without this is recording a hostname nothing resolves.
  def network_aliases(container_name:, network:)
    validate_name!(container_name)
    validate_name!(network)

    # SCOPED TO THE NETWORK ASKED ABOUT. Aggregating across every attached network
    # would certify a hostname the app cannot resolve — the alias has to be on the
    # network the app is actually on, or it resolves for someone else.
    # The network is a GO TEMPLATE string literal, not a shell word — the whole -f
    # value is already single-quoted for the shell, so shell-escaping it first and
    # then quoting would embed the backslashes in the lookup key. validate_name!
    # above is what makes the raw value safe to interpolate here.
    raw = run("docker inspect -f '{{with index .NetworkSettings.Networks #{network.to_s.inspect}}}" \
              "{{range .Aliases}}{{.}} {{end}}{{end}}' #{esc(container_name)}")
    raw.to_s.split(/\s+/).map(&:strip).reject(&:empty?)
  end

  private

  def container_exists?(name)
    result = run("docker ps -a --format '{{.Names}}'")
    result.split("\n").map(&:strip).include?(name)
  end

  def ensure_network(network)
    run("docker network inspect #{esc(network)} >/dev/null 2>&1 || docker network create #{esc(network)}")
  end

  def ensure_volume(volume)
    run("docker volume inspect #{esc(volume)} >/dev/null 2>&1 || docker volume create #{esc(volume)}")
  end

  def run_container(container_name:, volume:, network:, admin_username:, admin_password:, image:)
    run(
      "docker run -d --name #{esc(container_name)} --restart unless-stopped " \
      "--network #{esc(network)} -v #{esc(volume)}:/var/lib/postgresql/data " \
      "-e POSTGRES_USER=#{esc(admin_username)} -e POSTGRES_PASSWORD=#{esc(admin_password)} " \
      "-e POSTGRES_DB=postgres #{esc(image)}"
    )
  end

  # Poll pg_isready inside the container; give the volume/init a bounded window.
  def wait_ready(container_name, admin_username, tries: 30)
    tries.times do
      result = @ssh.execute_with_status(
        "docker exec #{esc(container_name)} pg_isready -U #{esc(admin_username)} -q"
      )
      return true if result[:success]

      sleep(1) unless Rails.env.test?
    end
    raise Error, "#{container_name} did not become ready"
  end

  def run(command)
    result = @ssh.execute_with_status(command)
    return result[:stdout].to_s if result[:success]

    raise Error, (@ssh.error.presence || result[:stderr].presence || "docker command failed")
  end

  def esc(value) = Shellwords.escape(value.to_s)

  def validate_name!(value)
    return if value.to_s.match?(NAME)

    raise Error, "Invalid docker object name: #{value.inspect}"
  end
end
