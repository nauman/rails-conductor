require "test_helper"

# ADR 0004's payoff: because containers carry the app's service label AND its
# infra revision, "is this artifact current?" is arithmetic rather than judgement.
class ResidueDetectorTest < ActiveSupport::TestCase
  class FakeSsh
    # A value of :fail makes that command fail, so fail-open is testable.
    def initialize(responses = {}) = @responses = responses

    # Longest match wins: the "is it BOTH?" query contains the same filters as
    # the individual ones, so a first-match fake would answer it wrongly.
    def execute_with_status(cmd)
      key = @responses.keys.select { |k| cmd.include?(k.to_s) }.max_by { |k| k.to_s.length }
      value = key ? @responses[key] : ""
      return { success: false, output: "", stderr: "permission denied" } if value == :fail

      { success: true, output: value, stderr: "" }
    end
  end

  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   edge_type: "kamal_proxy")
    @app = @org.apps.create!(name: "Starrrs", slug: "starrrs", server: @server, deploy_method: "docker",
                             port: 3000, domain: "starrrs.com",
                             repository_url: "https://github.com/x/y.git")
    @app.update_columns(infra_revision: 3)
  end

  def findings(responses) = ResidueDetector.new(@app, ssh: FakeSsh.new(responses)).findings

  test "a clean box reports nothing" do
    found = findings("conductor.infra_revision" => "abc|app-#{@app.id}-r3-sha|3|running")

    assert_empty found
  end

  # The Starrrs shape: a container from a previous form still running, invisible
  # because nothing compared it to the app's current revision.
  test "flags a container left over from an older revision" do
    found = findings(
      "conductor.infra_revision" => "old1|app-#{@app.id}-r2-oldsha|2|running\nnew1|app-#{@app.id}-r3-sha|3|running"
    )

    assert_equal 1, found.size
    assert_equal "stale_revision_container", found.first.kind
    assert_includes found.first.detail, "revision 2"
    assert_includes found.first.detail, "at 3"
  end

  test "does not flag containers at the current revision" do
    found = findings("conductor.infra_revision" => "a|app-#{@app.id}-r3-x|3|running\nb|app-#{@app.id}-r3-y|3|exited")

    assert_empty found.select { |f| f.kind == "stale_revision_container" }
  end

  test "flags a labelled container and the legacy name both serving" do
    found = findings(
      %(--filter "label=service=app-#{@app.id}") => "cid1",
      %(--filter "name=^/conductor-starrrs$") => "cid2"
    )

    dup = found.find { |f| f.kind == "duplicate_container" }
    assert dup, "two containers serving one app must be flagged"
    assert_includes dup.detail, "cid1"
    assert_includes dup.detail, "cid2"
  end

  # A boolean "do they overlap?" test suppressed this: the legacy container also
  # carries the stable label, so the old check saw an overlap and said nothing
  # even though a second release was running.
  test "flags two containers even when the legacy one also carries the label" do
    found = findings(
      %(--filter "label=service=app-#{@app.id}") => "cid1 cid2",
      %(--filter "name=^/conductor-starrrs$") => "cid2"
    )

    assert found.find { |f| f.kind == "duplicate_container" }, "overlap is not the same as one container"
  end

  test "a single container carrying both the label and the legacy name is fine" do
    found = findings(
      %(--filter "label=service=app-#{@app.id}") => "cid2",
      %(--filter "name=^/conductor-starrrs$") => "cid2"
    )

    assert_nil found.find { |f| f.kind == "duplicate_container" }
  end

  # An EMPTY revision label collapsed the whitespace field, so `state` was read
  # as the revision and every unlabelled container looked stale.
  test "an unlabelled container is not misread as stale" do
    found = findings("conductor.infra_revision" => "abc|some-other-container||running")

    assert_empty found.select { |f| f.kind == "stale_revision_container" }
  end

  # kamal-proxy supports path routing, so several services can legitimately serve
  # one host at different prefixes.
  test "path-routed services on one host are not duplicates" do
    found = findings(
      "kamal-proxy ls" => "Service   Host         Path      Target\n" \
                          "api-web   starrrs.com  /api      aaa:3000\n" \
                          "site-web  starrrs.com  /         bbb:3000\n"
    )

    assert_empty found.select { |f| f.kind == "duplicate_edge_route" },
                 "different paths are not a conflict"
  end

  test "two services on the SAME host and path are still flagged" do
    found = findings(
      "kamal-proxy ls" => "Service   Host         Path  Target\n" \
                          "old-web   starrrs.com  /     aaa:3000\n" \
                          "new-web   starrrs.com  /     bbb:3000\n"
    )

    assert found.find { |f| f.kind == "duplicate_edge_route" }
  end

  # kamal → docker leaves <service>-web-<version> behind.
  test "flags Kamal-era containers on an app that no longer deploys via Kamal" do
    found = findings("label=service=starrrs\" --format" => "starrrs-web-abc123|running")

    foreign = found.find { |f| f.kind == "foreign_method_container" }
    assert foreign
    assert_includes foreign.detail, "deploys via docker"
  end

  # The intermittent-502 shape: two services claiming one hostname.
  test "flags more than one proxy route claiming the host" do
    found = findings(
      "kamal-proxy ls" => "Service      Host         Target      State\n" \
                          "starrrs-web  starrrs.com  aaa:3000    running\n" \
                          "starrrs-com  starrrs.com  bbb:3000    running\n"
    )

    dup = found.find { |f| f.kind == "duplicate_edge_route" }
    assert dup, "two services for one host is the intermittent-502 shape"
    assert_includes dup.detail, "starrrs-web"
    assert_includes dup.detail, "starrrs-com"
  end

  test "a single proxy route is not residue" do
    found = findings("kamal-proxy ls" => "Service      Host         Target\nstarrrs-web  starrrs.com  aaa:3000\n")

    assert_empty found.select { |f| f.kind == "duplicate_edge_route" }
  end

  # Fail-open is the worst default for a detector: a broken docker daemon or a
  # permission error must not read as "clean box".
  test "a failed command reports blindness, not a clean box" do
    found = findings("conductor.infra_revision" => :fail)

    blind = found.find { |f| f.kind == "unknown" }
    assert blind, "a command that failed is not an empty result"
    assert_includes blind.remedy, "NOT a clean result"
  end

  # A detector that fails the deploy because it could not look is worse than none.
  test "reports blindness rather than raising when the box is unreachable" do
    broken = Object.new
    def broken.execute_with_status(_) = raise("connection refused")

    found = ResidueDetector.new(@app, ssh: broken).findings

    assert_equal 1, found.size
    assert_equal "unknown", found.first.kind
    assert_includes found.first.detail, "could not inspect"
  end

  test "native apps are skipped — their residue is not modelled yet" do
    @app.update_columns(deploy_method: "native")

    assert_empty findings("conductor.infra_revision" => "x|y|1|running")
  end

  # The calm.page case, and the reason this detector reported a clean box while a
  # hand sweep found real residue: check_edge_routes only compared routes to EACH
  # OTHER, so it never noticed a route pointing at a container that no longer
  # exists. calm.page moved to another box and left `calmpage-web ->
  # 35d45b624d67:3000` registered here; anything reaching this box for that host
  # 502s, and nothing said so for days.
  ROUTE_HEADER = "Service        Host           Path  Target             State    TLS".freeze

  def route_rows(*rows) = ([ ROUTE_HEADER ] + rows).join("\n")

  test "flags a route whose target container no longer exists" do
    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     deadbeef1234:3000  running  yes"),
      "--filter id=deadbeef1234" => "" # not running
    )

    orphan = found.find { |f| f.kind == "orphan_edge_route" }
    assert orphan, "expected an orphan_edge_route finding, got: #{found.map(&:kind).inspect}"
    assert_match(/deadbeef1234/, orphan.detail)
    assert_match(/starrrs\.com/, orphan.detail)
  end

  test "a route whose target is running is not flagged as an orphan" do
    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     abc123456789:3000  running  yes"),
      "--filter id=abc123456789" => "abc123456789|conductor-starrrs|starrrs"
    )

    assert_nil found.find { |f| f.kind == "orphan_edge_route" }
  end

  # A docker-deploy app legitimately serves from `conductor-<slug>`, which carries
  # no kamal service label. Flagging a missing label would have called Starrrs
  # broken while starrrs.com was serving 200 — so only a label belonging to a
  # DIFFERENT app counts as misrouting.
  test "does not flag an unlabelled target — that is how a docker deploy serves" do
    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     abc123456789:3000  running  yes"),
      "--filter id=abc123456789" => "abc123456789|conductor-starrrs|"
    )

    assert_empty found.select { |f| f.kind.start_with?("orphan_edge", "misrouted_edge") }
  end

  test "flags a target that is running but wears ANOTHER app's service label" do
    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     abc123456789:3000  running  yes"),
      "--filter id=abc123456789" => "abc123456789|kuickr-web-99|kuickr"
    )

    misrouted = found.find { |f| f.kind == "misrouted_edge_target" }
    assert misrouted, "expected misrouted_edge_target, got: #{found.map(&:kind).inspect}"
    assert_match(/kuickr/, misrouted.detail)
  end

  test "a failed container lookup reports blindness, never a clean route" do
    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     abc123456789:3000  running  yes"),
      "--filter id=abc123456789" => :fail
    )

    assert found.any? { |f| f.kind == "unknown" }, "a detector that cannot look must say so"
    assert_nil found.find { |f| f.kind == "orphan_edge_route" }
  end

  # I produced this false positive on myself: I compared a route table read hours
  # earlier against containers read now, and "concluded" conductor.pavelabs.io had
  # an orphan route while it served 200 — kamal had simply republished the route on
  # deploy. A deploy is precisely when a target legitimately changes mid-check, so
  # a route pointing at a vanished container during one proves nothing.
  test "an in-progress deployment suppresses edge-target findings" do
    @app.deployments.create!(status: "deploying")

    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     deadbeef1234:3000  running  yes"),
      "--filter id=deadbeef1234" => ""
    )

    assert_nil found.find { |f| f.kind == "orphan_edge_route" },
      "a route flipping mid-deploy is not residue"
  end

  test "a finished deployment does not suppress them" do
    @app.deployments.create!(status: "succeeded")

    found = findings(
      "kamal-proxy ls" => route_rows("starrrs-web    starrrs.com    /     deadbeef1234:3000  running  yes"),
      "--filter id=deadbeef1234" => ""
    )

    assert found.find { |f| f.kind == "orphan_edge_route" }
  end

  # calm.page accumulated ELEVEN dead containers from failed kamal boots — three in
  # `Created` (never started) plus four kamal `_replaced_` leftovers — and the
  # detector reported a clean box for all of them. Cause: every one carries an EMPTY
  # conductor.infra_revision label, and check_stale_revision_containers does
  # `next if revision.blank?`, so the whole pile was skipped by construction.
  #
  # A plain Exited release container is deliberately NOT flagged: kamal keeps those
  # so `kamal rollback` has something to boot. Flagging them would teach an operator
  # to delete their own rollback targets.
  test "flags containers that never started, even with no revision label" do
    found = findings(
      "docker ps -a" => "aa11|#{@app.resource_key}-web-abc|created\n" \
                        "bb22|#{@app.resource_key}-web-def|exited"
    )

    dead = found.select { |f| f.kind == "dead_container" }
    assert_equal 1, dead.size, "only the never-started one is junk: #{found.map(&:kind).inspect}"
    assert_match(/aa11|#{@app.resource_key}-web-abc/, dead.first.detail)
  end

  test "flags a kamal _replaced_ leftover that is no longer running" do
    found = findings(
      "docker ps -a" => "cc33|#{@app.resource_key}-web-latest_replaced_e0d5aad|exited"
    )

    dead = found.select { |f| f.kind == "dead_container" }
    assert_equal 1, dead.size
    assert_match(/_replaced_/, dead.first.detail)
  end

  test "a RUNNING _replaced_ container is not junk — it is what serves right now" do
    found = findings(
      "docker ps -a" => "dd44|#{@app.resource_key}-web-latest_replaced_e0d5aad|running"
    )

    assert_empty found.select { |f| f.kind == "dead_container" },
      "the live container was renamed by kamal but is still serving traffic"
  end

  test "a plain exited release container is left alone as rollback material" do
    found = findings("docker ps -a" => "ee55|#{@app.resource_key}-web-oldsha|exited")

    assert_empty found.select { |f| f.kind == "dead_container" }
  end
end
