require "test_helper"

# Plan 02 § 5.2 / § 9 step 7: the Rack::Attack sign-up throttles. The test env's
# cache is a null store, so each test gives Rack::Attack a real one.
class SignupThrottleTest < ActionDispatch::IntegrationTest
  PASS = Struct.new(:ok) { def verify(*, **) = ok }

  setup do
    User.create!(email: "ops@example.com", admin: true)
    @previous_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
  end

  teardown { Rack::Attack.cache.store = @previous_store }

  def submit(email, ip:)
    Turnstile.stub(:new, PASS.new(true)) do
      post signup_path, params: { email: email, terms: "1", "cf-turnstile-response" => "t" },
                        env: { "REMOTE_ADDR" => ip }
    end
  end

  test "five sign-up POSTs per IP per hour, then 429" do
    with_open_signup do
      5.times { |i| submit("u#{i}@example.com", ip: "198.51.100.1"); assert_response :redirect }
      submit("u6@example.com", ip: "198.51.100.1")
      assert_response :too_many_requests
      submit("other@example.com", ip: "198.51.100.2")
      assert_response :redirect, "another IP is unaffected"
    end
  end

  test "three sign-up POSTs per email per hour, across IPs, then 429" do
    with_open_signup do
      3.times { |i| submit("same@example.com", ip: "203.0.113.#{i + 1}"); assert_response :redirect }
      submit("SAME@example.com", ip: "203.0.113.9")
      assert_response :too_many_requests, "the email key is normalised"
    end
  end

  test "the throttle window resets after an hour" do
    with_open_signup do
      freeze_time
      5.times { |i| submit("w#{i}@example.com", ip: "198.51.100.7") }
      submit("w6@example.com", ip: "198.51.100.7")
      assert_response :too_many_requests
      travel 61.minutes
      submit("w7@example.com", ip: "198.51.100.7")
      assert_response :redirect
    end
  end
end
