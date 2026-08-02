require "test_helper"

# Does Conductor's idea of what is deployed match what is actually running?
#
# It did not, and nothing noticed. Conductor's newest record for an app deployed
# by an external script was a FAILED deploy from five days earlier against a
# retired box, while the app ran a different image elsewhere quite happily. A
# downstream agent took that stale SHA as its release baseline and planned a
# migration-verification protocol for migrations that were already applied.
#
# Being confidently wrong is worse than admitting ignorance, so this fails
# closed: if it cannot look, it says `unknown` and never `in_sync`.
class ReleaseDriftDetectorTest < ActiveSupport::TestCase
  class FakeSsh
    def initialize(response) = @response = response

    def execute_with_status(_cmd)
      return { success: false, output: "", stderr: "connection refused" } if @response == :fail

      { success: true, output: @response, stderr: "" }
    end
  end

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "InventList", slug: "inventlist", server: @server,
                             deploy_method: "docker", port: 3000,
                             repository_url: "https://github.com/x/y.git")
  end

  def detect(ps_output) = ReleaseDriftDetector.new(@app, ssh: FakeSsh.new(ps_output)).result

  def record_deploy!(sha, status: "succeeded")
    @app.deployments.create!(status: status, commit_sha: sha)
  end

  # ---------------------------------------------------------------- in sync

  test "recorded and running agree" do
    record_deploy!("abc123def456")
    r = detect("inventlist-web|ghcr.io/x/inventlist:abc123def456")

    assert_equal "in_sync", r.status
  end

  test "a short recorded sha still matches the full running one" do
    record_deploy!("abc123d")
    r = detect("inventlist-web|ghcr.io/x/inventlist:abc123def456789")

    assert_equal "in_sync", r.status, "the same commit written to different lengths is not drift"
  end

  # ------------------------------------------------------------------ drift

  # The InventList case.
  test "flags drift when the box runs something Conductor never recorded" do
    record_deploy!("f9404c6e112092512c32b3594b5d0193f53811a6", status: "failed")
    record_deploy!("aaaaaaa1111111111111111111111111111aaaa")
    r = detect("inventlist-web|ghcr.io/x/inventlist:8df23d148736389ecb5981bde952f795dc0f8519")

    assert_equal "drift", r.status
    assert_equal "8df23d148736389ecb5981bde952f795dc0f8519", r.running_sha
    assert_match "aaaaaaa", r.recorded_sha
    assert_match(/not what Conductor recorded/i, r.detail)
  end

  test "a failed deployment is never treated as the recorded release" do
    record_deploy!("bbbbbbb222222222222222222222222222bbbbb", status: "failed")
    r = detect("inventlist-web|ghcr.io/x/inventlist:bbbbbbb222222222222222222222222222bbbbb")

    assert_equal "unrecorded", r.status,
                 "a deploy that failed did not put that release on the box"
  end

  test "flags an app running with no successful deployment recorded at all" do
    r = detect("inventlist-web|ghcr.io/x/inventlist:8df23d148736389ecb5981bde952f795dc0f8519")

    assert_equal "unrecorded", r.status
    assert_nil r.recorded_sha
    assert_match(/no successful deployment/i, r.detail)
  end

  # ------------------------------------------------------- partial rollouts

  test "flags a half-rolled app whose containers disagree" do
    record_deploy!("abc123def456")
    r = detect([
      "inventlist-web|ghcr.io/x/inventlist:abc123def456",
      "inventlist-queue|ghcr.io/x/inventlist:abc123def456",
      "inventlist-scheduler|ghcr.io/x/inventlist:0000000ffffff"
    ].join("\n"))

    assert_equal "mixed_release", r.status
    assert_match "scheduler", r.detail
  end

  # --------------------------------------------------- failing closed

  test "an unreachable box is unknown, never in sync" do
    record_deploy!("abc123def456")
    r = ReleaseDriftDetector.new(@app, ssh: FakeSsh.new(:fail)).result

    assert_equal "unknown", r.status
    assert_match(/NOT a clean result/i, r.remedy)
  end

  test "no containers at all is reported as not running, not as agreement" do
    record_deploy!("abc123def456")
    r = detect("")

    assert_equal "not_running", r.status
  end

  test "an app with no server is unknown" do
    @app.update_columns(server_id: nil)
    r = ReleaseDriftDetector.new(@app).result

    assert_equal "unknown", r.status
  end

  # ------------------------------------------------------------- matching

  # Containers Conductor did not start carry no service label, so a label-only
  # lookup would find nothing and call a live app "not running".
  test "finds containers that carry no Conductor label" do
    record_deploy!("abc123def456")
    r = detect("inventlist-web|ghcr.io/x/inventlist:abc123def456")

    assert_equal "in_sync", r.status
  end

  test "ignores containers belonging to another app on a shared box" do
    record_deploy!("abc123def456")
    r = detect([
      "inventlist-web|ghcr.io/x/inventlist:abc123def456",
      "railslink-web|ghcr.io/x/railslink:99999999999",
      "some-postgres|postgres:16"
    ].join("\n"))

    assert_equal "in_sync", r.status, "another tenant's containers are not this app's release"
  end

  test "an image with no sha-shaped tag does not masquerade as a release" do
    record_deploy!("abc123def456")
    r = detect("inventlist-web|ghcr.io/x/inventlist:latest")

    assert_equal "unknown", r.status
    assert_match(/latest/, r.detail)
  end
end
