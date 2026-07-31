require "test_helper"

# The stored-rollup pattern: the job pays the SSH cost out of band, the fast
# paths read what it wrote. Wiring the detector directly into DeployPreflight
# hung the app detail page and would have stalled deploys on an unreachable box.
class ResidueCheckJobTest < ActiveSupport::TestCase
  setup do
    @org = Organization.create!(name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             repository_url: "https://github.com/x/y.git")
    @app.update_columns(deployed_at: Time.current)
  end

  def with_findings(findings)
    detector = Object.new
    detector.define_singleton_method(:findings) { findings }
    ResidueDetector.stub(:new, ->(*, **) { detector }) { ResidueCheckJob.perform_now(@app.id) }
    @app.reload
  end

  test "persists findings and stamps when it looked" do
    with_findings([ ResidueDetector::Finding.new(kind: "stale_revision_container",
                                                 detail: "old container", remedy: "remove it") ])

    assert_equal 1, @app.residue.size
    assert_equal "stale_revision_container", @app.residue.first[:kind]
    assert @app.residue_checked_at.present?
    assert @app.residue?
  end

  test "a clean result is recorded as checked-and-clean, not as unchecked" do
    with_findings([])

    assert_empty @app.residue
    assert @app.residue_checked_at.present?, "a clean check must still stamp the time"
    assert_not @app.residue?
  end

  # A failed diagnostic must not read as a healthy app.
  test "a crash is recorded as an unknown finding, not silence" do
    detector = Object.new
    detector.define_singleton_method(:findings) { raise "ssh exploded" }
    ResidueDetector.stub(:new, ->(*, **) { detector }) { ResidueCheckJob.perform_now(@app.id) }

    @app.reload
    assert_equal "unknown", @app.residue.first[:kind]
    assert_match(/ssh exploded/, @app.residue.first[:detail])
  end

  test "a result nobody has refreshed is reported as stale" do
    with_findings([])
    assert_not @app.residue_stale?

    @app.update_columns(residue_checked_at: (ResidueCheckJob::STALE_AFTER + 1.hour).ago)
    assert @app.residue_stale?
  end

  test "an app that has never been checked is stale by definition" do
    assert @app.residue_stale?
  end

  test "the sweep skips native apps and app-less servers" do
    @org.apps.create!(name: "Native", slug: "native", server: @server, deploy_method: "native",
                      repository_url: "https://github.com/x/y.git")
    detached = @org.apps.create!(name: "Detached", slug: "detached", deploy_method: "docker",
                                 repository_url: "https://github.com/x/y.git")

    enqueued = []
    ResidueCheckJob.stub(:perform_later, ->(id) { enqueued << id }) { ResidueCheckJob.sweep(@org) }

    assert_includes enqueued, @app.id
    assert_not_includes enqueued, detached.id, "no server means nothing to inspect"
    assert_equal 1, enqueued.size, "native residue is not modelled yet"
  end

  test "a missing app is a no-op rather than a crash" do
    assert_nothing_raised { ResidueCheckJob.perform_now(-1) }
  end
end
