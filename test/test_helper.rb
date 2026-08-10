ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"
require "net/ssh"

# No test may dial a real host. Two independent reviews on 2026-08-10 found tests
# that "passed" only because a live `Net::SSH.start` eventually errored and was
# rescued into an error string — one in the kamal deployer suite (~18s of every
# run), one in the converted-pages suite (a 10s timeout against 203.0.113.10).
# Both were invisible because the assertions still held.
#
# Refusing the connection INSTANTLY is the fix that breaks nothing: every service
# here already rescues ECONNREFUSED, so a test that was relying on a failed
# connection keeps its behaviour, loses the wall-clock, and stops depending on the
# machine's egress rules. A test that wants SSH to *work* injects a fake
# (`ssh: FakeSsh.new` or `SshConnection.stub(:new, …)`), which never reaches here.
#
# Set ALLOW_TEST_SSH=1 to opt out for a deliberate, manually-run integration check.
module NoRealSshInTests
  def start(host, *args, **kwargs, &block)
    return super if ENV["ALLOW_TEST_SSH"] == "1"

    raise Errno::ECONNREFUSED, "the test suite refused a real SSH connection to #{host} — " \
                               "inject a fake (ssh: FakeSsh.new, or SshConnection.stub(:new, …)) " \
                               "instead of relying on a live connect failing"
  end
end
Net::SSH.singleton_class.prepend(NoRealSshInTests)

module ActiveSupport
  class TestCase
    # Run tests in parallel. The pg gem segfaults in forked workers on macOS, so
    # default to single-process there; parallelize on Linux/CI. Override with
    # PARALLEL_WORKERS (e.g. PARALLEL_WORKERS=4 bin/rails test).
    workers =
      if ENV["PARALLEL_WORKERS"]
        ENV["PARALLEL_WORKERS"].to_i
      elsif RUBY_PLATFORM.include?("darwin")
        1
      else
        :number_of_processors
      end
    parallelize(workers: workers)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # A real, parseable ed25519 private key (SshKey#extract_key_metadata rejects
    # junk). Use for tests that need a server with ssh_configured? == true.
    def valid_private_key
      @valid_private_key ||= file_fixture("test_ed25519_key").read
    end
  end
end
