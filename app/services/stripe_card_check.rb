require "net/http"
require "json"

# The card check at sign-up (plan 02 § 3 step 3a, decision 3): a Stripe
# SetupIntent saves and verifies a card and NEVER charges it.
#
# Structural, not by convention: this client can reach exactly three Stripe
# endpoints — create a customer, create a SetupIntent, read a SetupIntent back.
# There is no code path to PaymentIntents, Charges or Invoices, and `request`
# refuses any other path, so "no charge is created" is a property of the class.
#
#   STRIPE_SECRET_KEY      — server-side (sk_test_… in development)
#   STRIPE_PUBLISHABLE_KEY — rendered into the card form (pk_test_…)
class StripeCardCheck
  class Error < StandardError; end

  API = "https://api.stripe.com".freeze
  ALLOWED = [
    [ "POST", %r{\A/v1/customers\z} ],
    [ "POST", %r{\A/v1/setup_intents\z} ],
    [ "GET",  %r{\A/v1/setup_intents/seti_[A-Za-z0-9]+\z} ]
  ].freeze

  def self.publishable_key = ENV["STRIPE_PUBLISHABLE_KEY"].presence
  def self.secret_key = ENV["STRIPE_SECRET_KEY"].presence
  def self.configured? = publishable_key.present? && secret_key.present?

  def initialize(http: nil)
    @http = http || method(:perform)
  end

  # Create (once) the org's Stripe customer and a fresh SetupIntent. Returns the
  # client_secret Stripe.js needs to collect and confirm the card in the browser.
  def start!(organization, email:)
    customer = organization.stripe_customer_id.presence ||
               request("POST", "/v1/customers", "email" => email,
                       "metadata[organization_id]" => organization.id.to_s).fetch("id")
    intent = request("POST", "/v1/setup_intents",
                     "customer" => customer, "usage" => "off_session",
                     "payment_method_types[]" => "card",
                     "metadata[organization_id]" => organization.id.to_s)
    organization.update!(stripe_customer_id: customer, stripe_setup_intent_id: intent.fetch("id"))
    intent.fetch("client_secret")
  end

  # Ask Stripe, never the browser, whether the card verified. The SetupIntent
  # must be the one we created for THIS org and must have succeeded.
  def complete!(organization, setup_intent_id)
    id = setup_intent_id.to_s
    raise Error, "That card check does not belong to this organization." if id.blank? || id != organization.stripe_setup_intent_id

    intent = request("GET", "/v1/setup_intents/#{id}")
    unless intent["customer"] == organization.stripe_customer_id &&
           intent.dig("metadata", "organization_id") == organization.id.to_s
      raise Error, "That card check does not belong to this organization."
    end
    raise Error, "The card could not be verified (#{intent['status']}). Try another card." unless intent["status"] == "succeeded"

    organization.update!(card_verified_at: Time.current)
    true
  end

  private

  def request(verb, path, params = {})
    raise Error, "refused Stripe call #{verb} #{path}" unless ALLOWED.any? { |v, re| v == verb && re.match?(path) }
    raise Error, "Card checks are not configured on this instance." unless self.class.secret_key

    status, body = @http.call(verb, path, params)
    json = JSON.parse(body.to_s)
    raise Error, json.dig("error", "message") || "Stripe returned #{status}" unless status.to_i.between?(200, 299)

    json
  rescue JSON::ParserError
    raise Error, "Stripe returned an unreadable response"
  end

  def perform(verb, path, params)
    uri = URI("#{API}#{path}")
    req = verb == "GET" ? Net::HTTP::Get.new(uri) : Net::HTTP::Post.new(uri)
    req.basic_auth(self.class.secret_key, "")
    req.set_form_data(params) unless verb == "GET"
    res = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 5, read_timeout: 15) { |h| h.request(req) }
    [ res.code, res.body ]
  end
end
