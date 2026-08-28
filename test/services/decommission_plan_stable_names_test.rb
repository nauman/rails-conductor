require "test_helper"

# THE MOST CONSEQUENTIAL VERSION OF A RECURRING BUG. Retiring an app discovered
# its containers by the kamal service label plus two guessed NAMES, and never by
# the stable `service=app-<id>` label that AppDeployer actually stamps on every
# container it starts (ADR 0004).
#
# So an app on the stable naming scheme could be "decommissioned" while its
# containers kept running — a retire that leaves the thing it retired serving is
# worse than one that fails, because nobody goes back to check.
#
# Same shape as a backup that dumped nothing and an orphan that ran for fifteen
# days: a lookup by a form the app had already outgrown.
class DecommissionPlanStableNamesTest < ActiveSupport::TestCase
  class RecordingSsh
    attr_reader :commands
    def initialize = (@commands = [])
    def execute_with_status(cmd)
      @commands << cmd
      { success: true, stdout: "", stderr: "" }
    end
  end

  setup do
    user = User.create!(email: "dc@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.6")
    @app = @org.apps.create!(name: "Shop", slug: "shop", server: @server, deploy_method: "docker",
                             port: 3000, repository_url: "https://github.com/x/y.git")
    @ssh = RecordingSsh.new
  end

  # Shellwords.escape turns `=` into `\=`, so compare against the unescaped text
  # rather than hand-writing backslashes into every assertion.
  def discover
    DecommissionPlan.new(app: @app, server: @server, ssh: @ssh).send(:discover_containers)
    @ssh.commands.map { |c| c.delete("\\") }
  end

  test "containers are discovered by the stable resource label" do
    assert discover.any? { |c| c.include?("label=service=#{@app.resource_key}") },
           "a retire that cannot see app-<id> leaves stable-named containers running"
  end

  # The resource key is not derivable from the slug, so the existing filters could
  # never have matched it. This asserts the gap is really closed, not renamed.
  test "the resource key is not already covered by the kamal service candidates" do
    assert_not_includes @app.kamal_service_candidates, @app.resource_key,
                        "precondition: app-<id> is a separate identity from the service name"
  end

  # The older lookups stay: containers predating the stable labels are still out
  # there, and a retire must find every form the app has ever taken.
  test "the legacy name lookups are kept as well" do
    cmds = discover

    assert cmds.any? { |c| c.include?("name=#{@app.container_name}") }, "legacy fixed name"
    assert cmds.any? { |c| c.include?("name=#{@app.slug}") }, "slug name"
    assert cmds.any? { |c| c.include?("label=service=#{@app.slug}") }, "kamal service label"
  end
end
