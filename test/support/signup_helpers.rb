# Helpers for the open hosted sign-up suite (plan 02). Included in every test case.
module SignupHelpers
  # Set environment variables for the duration of the block, then restore exactly
  # what was there before (including absence).
  def with_signup_env(vars)
    original = vars.keys.to_h { |k| [ k, ENV.key?(k) ? ENV[k] : :absent ] }
    vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v == :absent ? ENV.delete(k) : ENV[k] = v }
  end

  def with_open_signup(extra = {}, &block)
    with_signup_env({ "SIGNUP_MODE" => "open" }.merge(extra), &block)
  end

  # An organization as the open sign-up path creates it: a `new`, self-signed-up
  # tenant whose card is verified and whose first-run onboarding is done.
  def signed_up_tenant(email: "tenant@example.com", trust_level: "new", card: true, onboarded: true)
    user = User.create!(email: email, email_verified_at: Time.current)
    org = Organization.create_for(user, name: email.split("@").first)
    org.update!(trust_level: trust_level, signup_source: Organization::OPEN_SIGNUP,
                card_verified_at: (Time.current if card), onboarded_at: (Time.current if onboarded))
    [ user, org ]
  end
end

# Stands in for SshConnection in proof-of-control tests: returns a fixed probe
# output (or an error) without dialling anything.
class FakeOwnershipSsh
  attr_reader :error

  def initialize(output, error: nil)
    @output = output
    @error = error
  end

  def with_only_stored_key = yield(self)
  def execute(_command) = @output
end

ActiveSupport::TestCase.include(SignupHelpers)
ActionDispatch::IntegrationTest.include(SignupHelpers)
