require "net/http"
require "json"

# Is this exact commit already built and pushed?
#
# Asked BEFORE placing a build anywhere. A deploy of a commit that has already been
# built needs no build at all — it needs a pull — and today every such deploy rebuilds
# from scratch. That is the single largest saving available on any venue: it costs
# nothing on a machine you own and it costs CI minutes you may not have.
#
# It also fixes retries. A deploy that failed AFTER the image was pushed (edge
# republish, a migration, a health check) currently rebuilds the identical image to
# get back to the same place. This makes the second attempt start where the first
# one actually got to.
#
# The answer is deliberately conservative: anything other than a confirmed manifest
# is treated as "not built". A false yes would roll a tag that does not exist and
# take the app down; a false no costs one build. Those errors are not symmetrical,
# so unknown means no.
class RegistryImage
  Result = Struct.new(:exists, :registry, :reference, :detail, keyword_init: true) do
    def exists? = exists
  end

  def initialize(app, http: nil)
    @app = app
    @http = http
  end

  def exists?(sha) = check(sha).exists?

  def check(sha)
    return not_found(sha, "no image name recorded for this app") if image_name.blank?
    return not_found(sha, "no commit sha to look for") if sha.blank?

    manifest_present?(sha)
  rescue StandardError => e
    # Never raise into a deploy: an unreachable registry means "build it", which is
    # correct and merely costs time.
    not_found(sha, "registry unreachable (#{e.class}) — treating as not built")
  end

  private

  # Kamal's image reference, rebuilt from the same inputs kamal uses: the registry
  # server and username from the app's environment, and the image's own name. The
  # stored image_name may already carry a namespace ("acme/app"), and the registry
  # namespace is authoritative, so only the last segment is kept. Getting this wrong
  # is invisible — every lookup simply says "not built" and every build runs — which
  # is why it is derived rather than assumed.
  def image_name = @app.try(:image_name).presence || @app.slug

  def env = @env ||= (@app.respond_to?(:env_hash) ? @app.env_hash : {})

  def registry_host = env["KAMAL_REGISTRY_SERVER"].presence || "ghcr.io"

  def repository_path
    namespace = env["KAMAL_REGISTRY_USERNAME"].to_s.strip
    [ namespace, image_name.to_s.split("/").last ].reject(&:blank?).join("/")
  end

  # Docker Hub's API host differs from its registry name, and its token service is a
  # separate host again. Everything else follows the OCI distribution spec.
  def api_host
    %w[docker.io index.docker.io].include?(registry_host) ? "registry-1.docker.io" : registry_host
  end

  def token_endpoint
    if api_host == "registry-1.docker.io"
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository:#{repository_path}:pull"
    else
      "https://#{registry_host}/token?service=#{registry_host}&scope=repository:#{repository_path}:pull"
    end
  end

  def manifest_present?(sha)
    uri = URI("https://#{api_host}/v2/#{repository_path}/manifests/#{sha}")
    req = Net::HTTP::Head.new(uri)
    req["Accept"] = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
    token = pull_token
    req["Authorization"] = "Bearer #{token}" if token.present?

    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) { |h| h.request(req) }

    if res.is_a?(Net::HTTPSuccess)
      Result.new(exists: true, registry: registry_host, reference: "#{repository_path}:#{sha}",
                 detail: "manifest present — no build needed")
    else
      not_found(sha, "#{registry_host} answered #{res.code} for #{repository_path}")
    end
  end

  # These images are private, so an anonymous token is refused — the credential the
  # app already deploys with is exchanged for a pull-scoped token. Basic auth is sent
  # only to the registry's own token endpoint, never anywhere else, and the password
  # never leaves this method.
  def pull_token
    uri = URI(token_endpoint)
    req = Net::HTTP::Get.new(uri)
    password = env["KAMAL_REGISTRY_PASSWORD"].to_s
    username = env["KAMAL_REGISTRY_USERNAME"].to_s
    req.basic_auth(username, password) if password.present? && username.present?

    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(req) }
    return nil unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body)
    body["token"].presence || body["access_token"].presence
  rescue StandardError
    nil
  end

  def not_found(sha, detail) = Result.new(exists: false, reference: sha, detail: detail)
end
