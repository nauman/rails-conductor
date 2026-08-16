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

  def image_name = @app.try(:image_name).presence || @app.slug

  # GHCR and Docker Hub both speak the OCI distribution API; the difference is only
  # how a token is obtained. HEAD on the manifest is the cheapest possible question.
  def manifest_present?(sha)
    host, path = registry_coordinates
    uri = URI("https://#{host}/v2/#{path}/manifests/#{sha}")
    req = Net::HTTP::Head.new(uri)
    req["Accept"] = "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json"
    token = registry_token(host, path)
    req["Authorization"] = "Bearer #{token}" if token.present?

    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 8) { |h| h.request(req) }

    if res.is_a?(Net::HTTPSuccess)
      Result.new(exists: true, registry: host, reference: "#{path}:#{sha}", detail: "manifest present — no build needed")
    else
      not_found(sha, "registry answered #{res.code}")
    end
  end

  def registry_coordinates
    server = @app.try(:registry_server).presence || "ghcr.io"
    [ server, "#{registry_namespace}/#{image_name}".delete_prefix("/") ]
  end

  def registry_namespace = @app.try(:registry_username).presence || ""

  # Anonymous pulls work for public images, which is the common case here. A private
  # image without a token reads as "not built" — wrong, but it only costs a build.
  def registry_token(host, path)
    return @app.env_hash["KAMAL_REGISTRY_PASSWORD"] if host != "ghcr.io"

    uri = URI("https://ghcr.io/token?scope=repository:#{path}:pull")
    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 5) { |h| h.request(Net::HTTP::Get.new(uri)) }
    res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body)["token"] : nil
  rescue StandardError
    nil
  end

  def not_found(sha, detail) = Result.new(exists: false, reference: sha, detail: detail)
end
