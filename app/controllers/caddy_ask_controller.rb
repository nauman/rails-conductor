# The on-demand TLS gate Caddy calls before issuing a certificate.
#
# Caddy has ONE permission endpoint per instance while its policies are per-zone,
# so pointing it at an application means that application answers for EVERY zone on
# the box — and it answers 404 for every name that is not its own. That is how one
# zone's issuance silently died when another was enabled: the endpoint moved, and
# the new owner refused everything else.
#
# Conductor is the one process on the box that knows every zone, so the gate belongs
# here. It answers from the domains Conductor actually manages.
class CaddyAskController < ApplicationController
  # Caddy calls this unauthenticated, from the host, before a certificate exists.
  # A login redirect would read to Caddy as "refused" and no certificate would ever
  # be issued.
  skip_before_action :authenticate_user!, raise: false
  skip_before_action :verify_authenticity_token, raise: false
  allow_unauthenticated_access if respond_to?(:allow_unauthenticated_access)

  # 200 = issue it. Anything else = do not.
  #
  # DEFAULT TO NO. Caddy asks before issuing, so a gate that says yes to anything
  # invites unbounded issuance for any name someone points at this box — which ends
  # at a Let's Encrypt rate-limit that takes every certificate on the fleet with it.
  def show
    domain = params[:domain].to_s.strip.downcase
    return head :not_found if domain.blank?

    # WHICH BOX IS ASKING. Caddy sends only the domain, so without a token the gate
    # cannot tell one server from another and would answer for every zone on the
    # fleet — issuing certificates for names this machine does not serve, which is
    # both useless and a fast route to a rate-limit that takes every cert with it.
    server = Server.find_by(ask_token: params[:server].to_s) if params[:server].present?
    return head :not_found if server.nil?

    head permitted?(server, domain) ? :ok : :not_found
  end

  private

  # A name is permitted when an app ON THAT SERVER claims it: the apex itself, or any
  # label under it. Matching on the SUFFIX rather than a stored wildcard means a zone
  # works the moment its app has a domain, with no second thing to configure and
  # forget — which is how the last one broke.
  def permitted?(server, domain)
    server.apps.where.not(domain: [ nil, "" ]).pluck(:domain).any? do |claimed|
      claimed = claimed.to_s.strip.downcase
      next false if claimed.blank?

      domain == claimed || domain.end_with?(".#{claimed}")
    end
  end
end
