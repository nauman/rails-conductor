ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "minitest/mock"

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
