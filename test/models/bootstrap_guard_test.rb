require "test_helper"

# Plan 02 § 5.1 / § 9 step 1: an open instance never mints an admin from a
# stranger's email, and the one bootstrap path is safe under concurrency.
class BootstrapGuardTest < ActiveSupport::TestCase
  self.use_transactional_tests = false # the concurrency test needs real commits

  setup { wipe }
  teardown { wipe }

  test "invite-only mode keeps the first-email bootstrap for self-hosted installs" do
    with_signup_env("SIGNUP_MODE" => nil) do
      user = User.fetch_resource_for_passwordless("first@example.com")
      assert user.admin?
    end
  end

  test "open mode with an empty database creates no admin and no user" do
    with_open_signup do
      assert_nil User.fetch_resource_for_passwordless("first@example.com")
      assert_equal 0, User.count
    end
  end

  test "open mode bootstraps only BOOTSTRAP_ADMIN_EMAIL, and only while no admin exists" do
    with_open_signup("BOOTSTRAP_ADMIN_EMAIL" => "Ops@Example.com") do
      assert_nil User.fetch_resource_for_passwordless("stranger@example.com")

      admin = User.fetch_resource_for_passwordless("ops@example.com")
      assert admin.admin?

      User.where(id: admin.id).update_all(admin: false)
      User.create!(email: "other-admin@example.com", admin: true)
      demoted = User.fetch_resource_for_passwordless("ops@example.com")
      refute demoted.admin?, "an existing admin means the env bootstrap never re-promotes"
    end
  end

  test "concurrent bootstraps create exactly one admin" do
    with_signup_env("SIGNUP_MODE" => nil) do
      threads = 4.times.map do |i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            User.bootstrap_admin!("racer#{i}@example.com")
          rescue User::BootstrapRefused
            nil
          end
        end
      end
      threads.each(&:join)
      assert_equal 1, User.admins.count
      assert_equal 1, User.count, "the losers must not be left behind as ordinary users"
    end
  end

  test "boot refuses open mode with zero admins" do
    with_open_signup do
      assert_raises(SignupMode::BootRefused) { SignupMode.verify_boot! }
      User.create!(email: "ops@example.com", admin: true)
      assert_nil SignupMode.verify_boot!
    end
  end

  test "boot check is inert in invite-only mode" do
    with_signup_env("SIGNUP_MODE" => nil) do
      assert_nil SignupMode.verify_boot!(admins_exist: -> { false })
    end
  end

  test "the rake bootstrap creates one admin and refuses a second" do
    Rails.application.load_tasks unless Rake::Task.task_defined?("conductor:bootstrap_admin")
    task = Rake::Task["conductor:bootstrap_admin"]
    with_signup_env("EMAIL" => "ops@example.com") do
      task.reenable
      task.invoke
    end
    assert User.find_by(email: "ops@example.com").admin?

    with_signup_env("EMAIL" => "second@example.com") do
      task.reenable
      assert_raises(RuntimeError) { task.invoke }
    end
    assert_nil User.find_by(email: "second@example.com")
  end

  private

  def wipe
    Membership.delete_all
    Organization.delete_all
    User.delete_all
  end
end
