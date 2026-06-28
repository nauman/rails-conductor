# Public endpoint SCM providers POST push events to. Auth is the per-app HMAC
# signature (verified against App#webhook_secret over the RAW body) — not a
# session — so it inherits from ActionController::Base, not ApplicationController.
#
# Flow: verify signature → app must have auto_deploy on → the pushed ref must
# match the app's branch → debounce (skip if a deploy is already running) →
# enqueue the same DeployAppJob the UI/MCP use. No new deploy path.
class WebhooksController < ActionController::Base
  skip_forgery_protection

  def receive
    app = App.find_by(id: params[:app_id])
    head(:not_found) and return unless app
    head(:unauthorized) and return unless valid_signature?(app)

    head(:ok) and return unless app.auto_deploy?
    head(:ok) and return unless ref_matches_branch?(app)
    _deployment, already_running = app.start_deployment!
    head(:ok) and return if already_running # debounce

    head :accepted
  end

  private

  # GitHub: X-Hub-Signature-256: sha256=<hmac>. Compared over the raw body.
  def valid_signature?(app)
    return false if app.webhook_secret.blank?

    signature = request.headers["X-Hub-Signature-256"].to_s
    expected = "sha256=" + OpenSSL::HMAC.hexdigest("SHA256", app.webhook_secret, request.raw_post)
    ActiveSupport::SecurityUtils.secure_compare(expected, signature)
  end

  # GitHub push payload carries the full ref (refs/heads/<branch>). Compare to
  # the app's branch, defaulting to "main" like the deployers do.
  def ref_matches_branch?(app)
    ref = params.dig(:ref) || request.request_parameters["ref"]
    return true if ref.blank? # be lenient if a provider omits the ref

    branch = app.branch.presence || "main"
    ref == "refs/heads/#{branch}"
  end
end
