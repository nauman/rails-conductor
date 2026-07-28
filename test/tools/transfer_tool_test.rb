require "test_helper"

# conductor_app action=transfer — the invocable, confirm-gated transfer trigger.
class TransferToolTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @user = User.create!(email: "xfer-run@example.com", admin: true)
    @org = Organization.create_for(@user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @source = @org.servers.create!(name: "box-a", status: "online", ip_address: "10.0.0.1", ssh_key: key, edge_type: "caddy")
    @target = @org.servers.create!(name: "box-b", status: "online", ip_address: "10.0.0.2", ssh_key: key, edge_type: "caddy")
    @app = @org.apps.create!(name: "Appone", slug: "appone", server: @source, deploy_method: "kamal",
                             repository_url: "https://github.com/x/y.git", domain: "app.example.com")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare", api_key: "k", api_secret: "s", account_id: "a1")
  end

  def run_tool(**over)
    ConductorAppTool.new(user: @user).call({ "action" => "transfer", "app_name" => "Appone",
                                             "target_server_name" => "box-b" }.merge(over))
  end

  test "without confirm it previews and does nothing" do
    assert_no_enqueued_jobs do
      res = run_tool
      assert res.success?, res.error
      assert_equal false, res.value[:action_taken]
      assert_equal "confirmation_required", res.value[:status]
      assert_equal %w[database compute edge cutover drain], res.value[:steps].map { |s| s[:phase] }
    end
    assert_equal 0, AppTransfer.count, "no transfer record on a bare call"
  end

  test "with confirm it creates the transfer and enqueues the job" do
    res = nil
    assert_enqueued_with(job: AppTransferJob) do
      res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "conductor-transfers")
    end
    assert res.success?, res.error
    assert_equal "running", res.value[:status]
    assert_equal 1, AppTransfer.count
    t = AppTransfer.first
    assert_equal @app, t.app
    assert_equal @target, t.target_server
    assert_equal "transfer", t.mode
  end

  test "clone mode is honoured" do
    res = run_tool("confirm" => true, "mode" => "clone", "credential_id" => @cred.id, "bucket" => "b")
    assert res.success?, res.error
    assert_equal "clone", AppTransfer.first.mode
  end

  test "confirm without a credential is refused (no DB copy possible)" do
    res = run_tool("confirm" => true, "bucket" => "b")
    refute res.success?
    assert_match(/credential_id/, res.error)
    assert_equal 0, AppTransfer.count
  end

  test "confirm without a bucket is refused" do
    res = run_tool("confirm" => true, "credential_id" => @cred.id)
    refute res.success?
    assert_match(/bucket/, res.error)
  end

  test "same source and target is refused" do
    res = run_tool("target_server_name" => "box-a")
    refute res.success?
    assert_match(/differ/, res.error)
  end

  test "confirm with no source server is refused (revalidates the plan)" do
    @app.update!(server: nil)
    assert_no_enqueued_jobs do
      res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "b")
      refute res.success?
      assert_match(/source server/, res.error)
    end
    assert_equal 0, AppTransfer.count
  end

  test "shared-DB app is rejected up front (executor can't do it)" do
    @app.update!(database_mode: "shared")
    res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "b")
    refute res.success?
    assert_match(/dedicated database/, res.error)
    assert_equal 0, AppTransfer.count
  end

  test "non-Kamal app is rejected up front" do
    docker = @org.apps.create!(name: "Dock", slug: "dock", server: @source, deploy_method: "docker",
                               repository_url: "https://github.com/x/y.git")
    res = ConductorAppTool.new(user: @user).call("action" => "transfer", "app_name" => "Dock",
                                                 "target_server_name" => "box-b", "confirm" => true,
                                                 "credential_id" => @cred.id, "bucket" => "b")
    refute res.success?
    assert_match(/Kamal only/, res.error)
  end

  test "an unknown object-store provider is refused" do
    res = run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "b", "provider" => "not-a-vendor")
    refute res.success?
    assert_match(/provider/, res.error)
  end

  test "the selected provider is forwarded to the job" do
    captured = nil
    stub = ->(*_a, **kw) { captured = kw; nil }
    AppTransferJob.stub(:perform_later, stub) do
      run_tool("confirm" => true, "credential_id" => @cred.id, "bucket" => "b", "provider" => "aws_s3")
    end
    assert_equal "aws_s3", captured[:provider]
  end
end
