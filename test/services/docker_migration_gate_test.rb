require "test_helper"

# THE GATE WAS UNREACHABLE. AppDeployer serves docker apps only — native goes to
# NativeDeployer and kamal to KamalDeployer — and its run_gated_migrations opened
# with `return true unless app.kamal?`. So the migration gate, written and wired into
# both step lists, has never run for a single docker app.
#
# The failure it exists to prevent is the one already seen in production: code
# deployed that expects a column the database does not have, every request touching
# it returning 500, and the deployment recorded as succeeded.
class DockerMigrationGateTest < ActiveSupport::TestCase
  setup do
    @user = User.create!(email: "dmg@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.160")
    @subject = @org.apps.create!(name: "appone", slug: "appone", server: @server, deploy_method: "docker",
                                 port: 3000, repository_url: "https://github.com/x/y.git")
    @deployment = @subject.deployments.create!(user: @user, status: "deploying")
  end

  class FakeSsh
    attr_reader :commands
    def initialize(migrate_ok: true, pending_ok: true)
      @commands = []
      @migrate_ok = migrate_ok
      @pending_ok = pending_ok
    end

    def output = ""

    def execute_with_status(cmd)
      @commands << cmd
      return ok(@pending_ok) if cmd.include?("abort_if_pending_migrations")
      return ok(@migrate_ok) if cmd.include?("db:migrate")

      ok(true)
    end
    def error = nil

    private

    def ok(flag) = { success: flag, output: "", stdout: "", stderr: flag ? "" : "boom", exit_code: flag ? 0 : 1 }
  end

  def deployer(ssh)
    d = AppDeployer.new(@subject, @deployment)
    d.instance_variable_set(:@ssh, ssh)
    d
  end

  test "a docker app's migrations are gated" do
    ssh = FakeSsh.new
    assert deployer(ssh).send(:run_gated_migrations)

    migrate = ssh.commands.find { |c| c.include?("db:migrate") && !c.include?("abort_if") }
    assert migrate, "the gate must actually migrate"
    # A ONE-OFF container from the new image: it needs no host port, so it cannot
    # collide with the incumbent, and a failure means nothing has been touched.
    assert_includes migrate, "docker run --rm"
    assert_not_includes migrate, "docker exec", "migrating inside the release means the incumbent is already gone"
    assert ssh.commands.any? { |c| c.include?("abort_if_pending_migrations") },
           "migrating is not proof; the check after it is"
  end

  # The previous release keeps serving. A failed migration must not be followed by
  # code that expects the schema it failed to create.
  test "a failed migration stops the deploy" do
    ssh = FakeSsh.new(migrate_ok: false)

    assert_not deployer(ssh).send(:run_gated_migrations)
    assert_match(/db:migrate failed/i, @deployment.reload.log.to_s)
  end

  # THE CASE THAT CAUSED THE 500s: migrate exits zero but the schema still lags.
  test "migrations still pending after a successful migrate stops the deploy" do
    ssh = FakeSsh.new(pending_ok: false)

    assert_not deployer(ssh).send(:run_gated_migrations)
    assert_match(/pending migrations remain/i, @deployment.reload.log.to_s)
  end

  # DECLARED, not probed. Two probes were written and both could fail open — a
  # denied path traversal and a missing file both exit 1, and overriding the
  # entrypoint to probe bypasses any `cd` it performs. An app that runs Rails fine
  # would be read as "does not migrate" and skipped silently.
  test "an app declared as not migrating is skipped, with the reason recorded" do
    @subject.update!(migrates: false)
    ssh = FakeSsh.new

    assert deployer(ssh).send(:run_gated_migrations)
    assert_empty ssh.commands.grep(/db:migrate/)
    # An off gate must nag on every deploy, not whisper once: the upgrade backfill
    # switched it off for apps nobody decided about, and this line is the only place
    # that shows up.
    log = @deployment.reload.log.to_s
    assert_match(/MIGRATION GATE OFF/, log)
    assert_match(/out-of-date schema/i, log, "the nag has to say what goes wrong, not just what was skipped")
  end

  test "migrating is the default, so a new app is gated without anyone opting in" do
    assert @subject.migrates?, "the safe default is to gate; opting out is deliberate"
  end

  # The guard lives in the SHARED discard, not in one caller: health-check failure
  # and cutover compensation arrive by their own routes, and a protection only one of
  # three paths honours is not a protection.
  test "no failure path removes the serving container when it was adopted" do
    ssh = FakeSsh.new
    d = deployer(ssh)
    d.instance_variable_set(:@candidate_name, "app-1-r1-abc")
    d.instance_variable_set(:@candidate_container, "cid-live")
    d.instance_variable_set(:@previous_container, "cid-live")

    # NB: the return values are deliberately NOT the assertion here. Both the
    # guarded and the destructive branch return false, so asserting on them would
    # pass either way. The evidence is what did NOT reach the shell.
    d.send(:fail_release_gate, "migrations failed")
    d.send(:discard_candidate, "candidate never became healthy")

    assert_empty ssh.commands.grep(/docker rm/), "no path may remove the serving container"
    # And it must not go quiet about it: we cannot tell an incumbent from a leftover
    # here, so the one we keep has to be visible if the guess was wrong.
    log = @deployment.reload.log.to_s
    assert_match(/adopted as already-serving/i, log)
    assert_match(/residue check/i, log, "an orphan nobody is told about is the expensive kind")
  end

  # WHERE the gate sits in the sequence IS the fix. Calling the method directly
  # proves it refuses; it does not prove the deploy ever calls it, nor that it is
  # called while the previous release is still up. Moving it one slot later — after
  # stop_old_container — reinstates the exact bug this work exists to close: a
  # failed migration with the incumbent already gone, and a log claiming "the
  # previous release keeps serving".
  test "the gate runs in both orders, and before anything is stopped or started" do
    {
      AppDeployer::ZERO_DOWNTIME_STEPS => :start_candidate,
      AppDeployer::STOP_FIRST_STEPS => :stop_old_container
    }.each do |steps, first_destructive|
      gate = steps.index(:run_gated_migrations)
      assert gate, "every deploy order must run the migration gate: #{steps.inspect}"
      assert gate < steps.index(first_destructive),
        "the gate must precede #{first_destructive}: a migration that fails after it " \
        "leaves the app down, which is what this ordering was written to prevent"
    end
  end

  # The throwaway container has to reach the same database the release will, or it
  # verifies a schema nobody serves. Network, env and image reference are each
  # load-bearing and each silently droppable.
  test "the migration container carries the release's own env, network and image" do
    @subject.env_variables.create!(key: "DOCKER_NETWORK", value: "app-net")
    @subject.env_variables.create!(key: "PLAIN_SETTING", value: "visible")
    d = deployer(FakeSsh.new)
    command = d.send(:migration_command, "bin/rails db:migrate")

    assert_match(/\Adocker run --rm\b/, command)
    assert_match(/--network app-net/, command, "a migration off the app's network cannot see its database")
    assert_match(/RAILS_ENV=production/, command)
    # The IMAGE is the whole point: migrating with the old image verifies the schema
    # against the code being replaced, which is the failure this gate exists to catch.
    assert_match(/#{Regexp.escape(d.send(:image_ref, d.send(:release_tag)))}/, command,
      "the gate must run the image about to be released, not the one already serving")
    assert_match(/PLAIN_SETTING=/, command, "a migration without the app's env cannot reach its database")
    assert_match(/bin\/rails db:migrate\z/, command)
    assert_no_match(/-p |--publish/, command,
      "publishing a port would collide with the incumbent still serving on it")
  end
end
