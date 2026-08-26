require "test_helper"

# The incident this job exists for: reclaim ran in an MCP request, the proxy
# returned 504 mid-`swapoff -a`, and the box came back with 471 MiB less swap than
# it started with. The wrapper's own restore logic was irrelevant — its process had
# been killed. So the contract under test is not "does it reclaim" but "is it
# somewhere it cannot be interrupted, and does it leave a readable record".
class ReclaimSwapJobTest < ActiveJob::TestCase
  setup do
    user = User.create!(email: "swapjob@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "192.0.2.10",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  test "the tool enqueues and returns instead of holding the request open" do
    tool = ReclaimSwapTool.new(user: @org.users.first)

    assert_enqueued_with(job: ReclaimSwapJob, args: [ @server.id ]) do
      result = tool.call({ "server_id" => @server.id })
      assert result.success?
      assert_equal "running", result.value[:status]
    end

    assert_equal "running", @server.reload.last_swap_reclaim_status
  end

  test "records the outcome so a severed connection is never mistaken for silence" do
    stub_reclaim(success: true, message: "reclaimed 2096508K; 1 swap device(s) active") do
      ReclaimSwapJob.perform_now(@server.id)
    end

    @server.reload
    assert_equal "succeeded", @server.last_swap_reclaim_status
    assert_includes @server.last_swap_reclaim_log, "1 swap device(s) active"
    assert @server.last_swap_reclaim_at.present?
  end

  test "a failure is recorded as failed, not silently dropped" do
    stub_reclaim(success: false, message: "URGENT: swap is OFF") do
      ReclaimSwapJob.perform_now(@server.id)
    end

    @server.reload
    assert_equal "failed", @server.last_swap_reclaim_status
    assert_includes @server.last_swap_reclaim_log, "URGENT"
  end

  test "a deleted server is a no-op, not a crash" do
    id = @server.id
    @server.destroy
    assert_nothing_raised { ReclaimSwapJob.perform_now(id) }
  end

  private

  def stub_reclaim(success:, message:, &block)
    fake = Object.new
    fake.define_singleton_method(:reclaim!) { ServerSwapReclaim::Result.new(success: success, message: message) }
    ServerSwapReclaim.stub(:new, ->(_server) { fake }, &block)
  end
end
