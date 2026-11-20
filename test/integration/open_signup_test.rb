require "test_helper"

# Plan 02 § 3, § 9 steps 6, 6a, 7 and 9: the sign-up path end to end.
class OpenSignupTest < ActionDispatch::IntegrationTest
  include ActionMailer::TestHelper

  PASS = Struct.new(:ok) { def verify(*, **) = ok }

  # Records every Stripe call and answers like test mode would.
  class FakeStripe
    attr_reader :calls
    attr_accessor :status

    def initialize(status: "succeeded")
      @calls = []
      @status = status
    end

    def call(verb, path, params)
      @calls << [ verb, path, params ]
      case [ verb, path ]
      in [ "POST", "/v1/customers" ] then [ 200, { id: "cus_test1" }.to_json ]
      in [ "POST", "/v1/setup_intents" ]
        @org_id = params["metadata[organization_id]"]
        [ 200, { id: "seti_test1", client_secret: "seti_test1_secret_x" }.to_json ]
      in [ "GET", "/v1/setup_intents/seti_test1" ]
        [ 200, { id: "seti_test1", status: status, customer: "cus_test1", metadata: { organization_id: @org_id } }.to_json ]
      end
    end
  end

  setup do
    User.create!(email: "ops@example.com", admin: true) # an open instance always has an admin
    @env = { "SIGNUP_MODE" => "open", "TURNSTILE_SITE_KEY" => "1x00000000000000000000AA",
             "TURNSTILE_SECRET_KEY" => "1x0000000000000000000000000000000AA",
             "STRIPE_SECRET_KEY" => "sk_test_x", "STRIPE_PUBLISHABLE_KEY" => "pk_test_x" }
  end

  def submit(email, terms: "1", human: true)
    Turnstile.stub(:new, PASS.new(human)) do
      post signup_path, params: { email: email, terms: terms, "cf-turnstile-response" => "tok" }
    end
  end

  def signup_link_token
    mail = ActionMailer::Base.deliveries.last
    mail.text_part.body.to_s[%r{/signup/verify/([A-Za-z0-9_-]+)}, 1]
  end

  test "invite-only (the default) serves no sign-up at all" do
    with_signup_env("SIGNUP_MODE" => nil) do
      get signup_path
      assert_response :not_found
      post signup_path, params: { email: "x@example.com", terms: "1" }
      assert_response :not_found
      assert_equal 0, SignupIntent.count
    end
  end

  test "an open instance with no admin serves no sign-up" do
    User.update_all(admin: false)
    with_signup_env(@env) do
      get signup_path
      assert_response :not_found
    end
  end

  test "the response is identical for a new and an existing email, and neither creates a user" do
    User.create!(email: "known@example.com")
    with_signup_env(@env) do
      users_before = User.count

      assert_enqueued_jobs(1) { submit("fresh@example.com") }
      fresh = [ response.status, response.location ]
      assert_enqueued_jobs(1) { submit("known@example.com") }
      known = [ response.status, response.location ]

      assert_equal fresh, known
      follow_redirect!
      assert_match "If that address can use Conductor", response.body
      assert_equal users_before, User.count, "no account exists before the link is clicked"
      assert_equal 1, SignupIntent.count, "only the unknown address gets an intent"
    end
  end

  test "clicking the link creates a verified non-admin user in a new self-signed-up org, then demands a card" do
    with_signup_env(@env) do
      perform_enqueued_jobs { submit("Founder@Example.com") }
      assert_nil User.find_by(email: "founder@example.com")

      post verify_signup_path(token: signup_link_token)
      assert_redirected_to card_check_path

      user = User.find_by!(email: "founder@example.com")
      refute user.admin?
      assert user.email_verified_at
      org = user.organizations.sole
      assert_equal "new", org.trust_level
      assert org.self_signed_up?
      assert org.owner?(user)
      assert_nil org.github_app_granted_at, "a sign-up never gets the instance GitHub App"

      get servers_path
      assert_redirected_to card_check_path, "no onboarding or anything else before the card check"
    end
  end

  test "opening the link only shows a confirm page; a mail scanner's GET creates nothing" do
    with_signup_env(@env) do
      perform_enqueued_jobs { submit("scanned@example.com") }
      token = signup_link_token
      get verify_signup_path(token: token)
      assert_response :success
      assert_match "Create my account", response.body
      assert_nil User.find_by(email: "scanned@example.com")
      post verify_signup_path(token: token)
      assert_redirected_to card_check_path
    end
  end

  test "without a card: no server registration, no MCP, no API, no OAuth grant" do
    user, org = sign_up_and_sign_in!
    get onboarding_server_path
    assert_redirected_to card_check_path
    post onboarding_server_path, params: { server: { name: "x", ip_address: "8.8.8.8" } }
    assert_redirected_to card_check_path
    assert_equal 0, org.servers.count

    raw, = ApiToken.generate(user: user, name: "t", organization: org)
    post "/mcp/call", params: { name: "conductor_read", input: { action: "fleet_status" } },
         headers: { "Authorization" => "Bearer #{raw}" }, as: :json
    assert_match(/card check/, response.body)
    get "/api/v1/servers", headers: { "Authorization" => "Bearer #{raw}" }
    assert_response :forbidden
    assert_match(/card check/, response.body)
  end

  test "a link works once" do
    with_signup_env(@env) do
      perform_enqueued_jobs { submit("once@example.com") }
      token = signup_link_token
      post verify_signup_path(token: token)
      delete user_sign_out_path
      post verify_signup_path(token: token)
      assert_response :unprocessable_entity
      assert_equal 1, User.where(email: "once@example.com").count
    end
  end

  test "an expired link creates nothing" do
    with_signup_env(@env) do
      perform_enqueued_jobs { submit("late@example.com") }
      token = signup_link_token
      travel 25.hours do
        post verify_signup_path(token: token)
        assert_response :unprocessable_entity
      end
      assert_nil User.find_by(email: "late@example.com")
    end
  end

  test "an unknown token is a 404" do
    with_signup_env(@env) do
      get verify_signup_path(token: "nope")
      assert_response :not_found
    end
  end

  test "form errors: terms, disposable inbox, failed human check" do
    with_signup_env(@env) do
      submit("a@example.com", terms: "0")
      assert_response :unprocessable_entity
      submit("a@mailinator.com")
      assert_response :unprocessable_entity
      assert_match "disposable", response.body
      submit("a@sub.mailinator.com")
      assert_response :unprocessable_entity
      submit("a@example.com", human: false)
      assert_response :unprocessable_entity
      assert_equal 0, SignupIntent.count
    end
  end

  test "the human check fails closed when Turnstile is not configured" do
    with_signup_env(@env.merge("TURNSTILE_SECRET_KEY" => nil)) do
      post signup_path, params: { email: "a@example.com", terms: "1", "cf-turnstile-response" => "tok" }
      assert_response :unprocessable_entity
    end
  end

  test "no more than three verified sign-ups per /24 per day" do
    with_signup_env(@env) do
      4.times do |i|
        intent, raw = SignupIntent.start!(email: "n#{i}@example.com", ip: "198.51.100.#{i + 1}")
        i < 3 ? intent.consume! : assert_raises(SignupIntent::Refused) { intent.consume! }
      end
      assert_equal 3, User.where("email LIKE 'n%@example.com'").count
      intent, = SignupIntent.start!(email: "other-net@example.com", ip: "192.0.2.7")
      assert intent.consume!
    end
  end

  test "card check: a SetupIntent verifies the card and nothing is ever charged" do
    _user, org = sign_up_and_sign_in!
    stripe = FakeStripe.new
    with_signup_env(@env) do
      StripeCardCheck.stub(:new, StripeCardCheck.new(http: stripe)) do
        get card_check_path
        assert_response :success
        assert_match "js.stripe.com/v3", response.body

        post card_check_intent_path, as: :json
        assert_equal "seti_test1_secret_x", response.parsed_body["client_secret"]

        get complete_card_check_path(setup_intent: "seti_test1")
        assert_redirected_to onboarding_path
      end
    end
    assert org.reload.card_verified?
    paths = stripe.calls.map { |verb, path, _| "#{verb} #{path}" }
    assert_equal [ "POST /v1/customers", "POST /v1/setup_intents", "GET /v1/setup_intents/seti_test1" ], paths
    refute paths.any? { |p| p.match?(/payment_intents|charges|invoices/) }, "no charge is ever created"
    assert_equal "off_session", stripe.calls[1][2]["usage"]
  end

  test "card check: a declined card blocks onboarding" do
    _user, org = sign_up_and_sign_in!
    with_signup_env(@env) do
      StripeCardCheck.stub(:new, StripeCardCheck.new(http: FakeStripe.new(status: "requires_payment_method"))) do
        post card_check_intent_path, as: :json
        get complete_card_check_path(setup_intent: "seti_test1")
        assert_redirected_to card_check_path
        get card_check_path
        assert_response :success # only the card step itself is reachable…
        get onboarding_path
        assert_redirected_to card_check_path # …not onboarding…
        get servers_path
        assert_redirected_to card_check_path # …and not anything else
      end
    end
    refute org.reload.card_verified?
  end

  test "card check: another org's SetupIntent is refused" do
    _user, org = sign_up_and_sign_in!
    with_signup_env(@env) do
      StripeCardCheck.stub(:new, StripeCardCheck.new(http: FakeStripe.new)) do
        post card_check_intent_path, as: :json
        get complete_card_check_path(setup_intent: "seti_someoneelse")
        assert_redirected_to card_check_path
      end
    end
    refute org.reload.card_verified?
  end

  test "the Stripe client cannot reach a charge endpoint at all" do
    client = StripeCardCheck.new(http: ->(*) { flunk "must not dial" })
    with_signup_env("STRIPE_SECRET_KEY" => "sk_test_x") do
      %w[/v1/payment_intents /v1/charges /v1/invoices].each do |path|
        assert_raises(StripeCardCheck::Error) { client.send(:request, "POST", path, {}) }
      end
    end
  end

  test "kill switch: flipping back to invite-only closes sign-up and pending links, not existing users" do
    with_signup_env(@env) do
      perform_enqueued_jobs { submit("pending@example.com") }
    end
    token = signup_link_token
    existing = User.create!(email: "member@example.com")
    Organization.create_for(existing, name: "m").update!(onboarded_at: Time.current)

    with_signup_env("SIGNUP_MODE" => "invite_only") do
      post verify_signup_path(token: token)
      assert_response :not_found
      assert_nil User.find_by(email: "pending@example.com")

      ps = Passwordless::Session.create!(authenticatable: existing)
      get "/users/sign_in/#{ps.identifier}/#{ps.token}"
      get servers_path
      assert_response :success, "existing users keep working"
    end
  end

  test "the purge job removes intents older than 24 hours" do
    old, = SignupIntent.start!(email: "old@example.com", ip: "192.0.2.1")
    old.update_columns(created_at: 25.hours.ago)
    fresh, = SignupIntent.start!(email: "fresh@example.com", ip: "192.0.2.1")
    PurgeSignupIntentsJob.perform_now
    assert_equal [ fresh.id ], SignupIntent.pluck(:id)
  end

  test "the daily mail cap stops sending but keeps the neutral answer" do
    TenantLimits.store = ActiveSupport::Cache::MemoryStore.new
    with_signup_env(@env.merge("SIGNUP_DAILY_MAIL_CAP" => "1")) do
      assert_enqueued_jobs(1) { submit("one@example.com") }
      assert_enqueued_jobs(0) { submit("two@example.com") }
      assert_redirected_to signup_sent_path
    end
  ensure
    TenantLimits.store = nil
  end

  private

  def sign_up_and_sign_in!
    with_signup_env(@env) do
      intent, = SignupIntent.start!(email: "card@example.com", ip: "192.0.2.50")
      user = intent.consume!
      ps = Passwordless::Session.create!(authenticatable: user)
      get "/users/sign_in/#{ps.identifier}/#{ps.token}"
      [ user, user.organizations.sole ]
    end
  end
end
