require "net/http"
require "json"

# Can anyone read this app's image?
#
# A container image carries the application's source. Pushing one to a public
# repository publishes that source, and nothing in a deploy says so out loud —
# the image name looks the same either way. This asks the registry the question
# an attacker would ask, ANONYMOUSLY, and it asks about the repository the deploy
# actually pushes to rather than one derived a second time (see KamalConfig).
#
# It must be anonymous. Probing with the app's own credential can only ever
# answer "yes, I can see it", which says nothing about what the world can see.
#
# THE ANSWERS ARE NOT SYMMETRIC, and neither are the mistakes:
#
#   readable  — a positive, self-evidencing fact. Public. Block the deploy.
#   refused   — private OR never pushed. The registry returns the same 401/403/404
#               for both, so this is only ever "not published", never "private".
#   anything else — unknown. Say so.
#
# A false "public" blocks a deploy, and the only override is Force, which bypasses
# EVERY other gate — so a probe that cries wolf trains people to skip the audit and
# seed gates too. A false "not public" lets one image through, which the next
# deploy's probe catches. That asymmetry is why nothing here guesses upward.
class RegistryVisibility
  # A repository an anonymous caller is expected to be able to list, per registry.
  #
  # It exists to prove the probe still WORKS. Without it, a probe that can see
  # nothing at all — blocked egress, a proxy answering 401, a token service that
  # changed shape — answers "refused" for every repository, and "refused" is the
  # answer that CLEARS an app. One blind network and every image on the fleet
  # reads as private. That is the exact failure this gate exists to prevent, so
  # it is not allowed to be the way the gate fails.
  CONTROLS = {
    "registry-1.docker.io" => "library/alpine",
    "ghcr.io"              => "actions/actions-runner"
  }.freeze

  Result = Struct.new(:status, :registry, :repository, :detail, keyword_init: true) do
    def public?  = status == :public
    def unknown? = status == :unknown
  end

  def initialize(app, http: nil)
    @app = app
    @http = http
  end

  def check
    status, detail = probe(repository)

    return result(:public, "#{reference} can be listed by an anonymous caller — the image, " \
                           "and the source baked into it, is published") if status == :readable
    return result(:unknown, detail) unless status == :refused

    cleared_by_control(detail)
  end

  private

  # "Refused" only means "not published" if this probe can still recognise
  # something that IS published. Checked second, so a genuinely public repository
  # is reported without the extra round trip.
  def cleared_by_control(detail)
    control = CONTROLS[api_host]
    if control.nil?
      return result(:unknown,
                    "#{reference} answered #{detail}, but Conductor has no control repository for " \
                    "#{registry_host}, so it cannot tell a private repository from a probe that " \
                    "can see nothing at all")
    end

    control_status, control_detail = probe(control)
    if control_status == :readable
      result(:not_public, "#{reference} is not listable by an anonymous caller (#{detail})")
    else
      result(:unknown,
             "#{reference} answered #{detail}, and so did the control repository #{control} " \
             "(#{control_detail}) — this probe cannot currently see a repository that is known to " \
             "be public, so it cannot clear anything")
    end
  end

  # Listing tags is the cheapest question that distinguishes public from private,
  # and it needs no tag or digest — so it works on an app that has never shipped.
  #
  # Timeouts are deliberately short. This runs inside the synchronous deploy
  # trigger, and a probe worth up to two round trips (repository, then control)
  # against a hung registry would make a human wait, or a request time out, for a
  # check whose own answer to "no reply" is merely a warning.
  def probe(repo)
    uri = URI("https://#{api_host}/v2/#{repo}/tags/list")
    req = Net::HTTP::Get.new(uri)
    token = anonymous_token(repo)
    req["Authorization"] = "Bearer #{token}" if token.present?

    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 4) { |h| h.request(req) }

    case res
    when Net::HTTPSuccess then [ :readable, res.code ]
    when Net::HTTPUnauthorized, Net::HTTPForbidden, Net::HTTPNotFound then [ :refused, res.code ]
    else [ :unknown, "#{registry_host} answered #{res.code}" ]
    end
  rescue StandardError => e
    [ :unknown, "#{registry_host} unreachable (#{e.class}) — visibility unverified" ]
  end

  # Deliberately credential-free: a public repository hands out a pull token to
  # anyone, and a private one refuses. A refusal here is not an error, it is part
  # of the answer, so the tags request goes out unauthenticated and the registry
  # states its own verdict.
  def anonymous_token(repo)
    uri = URI(RegistryEndpoints.token_url(registry_host, repo))
    res = (@http || Net::HTTP).start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 3) { |h| h.request(Net::HTTP::Get.new(uri)) }
    return nil unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body)
    body["token"].presence || body["access_token"].presence
  rescue StandardError
    nil
  end

  def config = @config ||= KamalConfig.new(@app)

  # The repository THIS DEPLOY PUSHES TO, taken from the config that writes it.
  # Deriving it again here is how a check ends up truthfully answering about a
  # repository nobody ships to.
  def repository    = config.image_repository
  def registry_host = config.image_registry
  def api_host      = RegistryEndpoints.api_host(registry_host)
  def reference     = "#{registry_host}/#{repository}"

  def result(status, detail)
    Result.new(status: status, registry: registry_host, repository: repository, detail: detail)
  end
end
