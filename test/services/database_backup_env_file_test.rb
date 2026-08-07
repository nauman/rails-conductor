require "test_helper"

# intellecta.co runs as a Hatchbox app: systemd + puma on the host, DATABASE_URL
# in /home/deploy/<app>/.asdf-vars, database in the HOST postgres. No container.
#
# Conductor had no way to reach that. `resolve_database_url` found nothing, and
# the last-resort branch ran `pg_dump "$DATABASE_URL"` against a variable that is
# not set in a non-interactive SSH session. What it dumped instead was an
# abandoned, empty `intellectaco-db` container from a half-finished migration —
# a green backup protecting nothing.
class DatabaseBackupEnvFileTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    def initialize(responses = {})
      @responses = responses
      @commands = []
    end

    def execute(cmd)
      execute_with_status(cmd)[:output]
    end

    def execute_with_status(cmd)
      @commands << cmd
      key = @responses.keys.select { |k| cmd.include?(k.to_s) }.max_by { |k| k.to_s.length }
      v = key ? @responses[key] : { success: true, output: "" }
      @last_output = v[:output].to_s
      { success: v.fetch(:success, true), exit_code: v.fetch(:success, true) ? 0 : 1,
        output: @last_output, stderr: "" }
    end

    def output = @last_output
    def error = "err"

    def dump_command = @commands.find { |c| c.include?("pg_dump") }
  end

  setup do
    user = User.create!(email: "envfile@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1",
                                   ssh_key: SshKey.create!(name: "k", private_key: valid_private_key,
                                                           organization: @org))
    @app = @org.apps.create!(name: "intellectaco", slug: "intellectaco",
                             server: @server, deploy_method: "native")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare",
                                     api_key: "AK", api_secret: "SK", account_id: "a1")
  end

  def backup_with(env_file:)
    @org.backups.create!(provider: "cloudflare_r2", bucket_name: "buck", credential: @cred,
                         server: @server, app: @app, schedule: "daily", enabled: true,
                         env_file: env_file)
  end

  # No container anywhere: `docker ps -q -f name=intellectaco-db` returns nothing.
  def host_app_responses
    {
      "docker ps"   => { success: true, output: "" },
      "pg_dump"     => { success: true, output: "" },
      "gzip -t"     => { success: true, output: "" },
      "stat"        => { success: true, output: "5000000" },
      "command -v aws" => { success: true, output: "/usr/bin/aws" },
      "aws s3 cp"   => { success: true, output: "" },
      "aws s3 ls"   => { success: true, output: "2026-08-07 06:00:01 5000000 x.sql.gz" },
      "list-objects-v2" => { success: true, output: "" }
    }
  end

  test "the env file is sourced before pg_dump so DATABASE_URL is set" do
    ssh = FakeSsh.new(host_app_responses)
    DatabaseBackup.new(backup_with(env_file: "/home/deploy/intellectaco/.asdf-vars"), ssh: ssh).run!

    cmd = ssh.dump_command
    assert cmd.include?(".asdf-vars"), "the env file must be sourced: #{cmd}"
    assert cmd.include?("pg_dump"), cmd
    assert cmd.index(".asdf-vars") < cmd.index("pg_dump"),
           "sourcing must happen BEFORE pg_dump, or DATABASE_URL is still unset"
  end

  # The path reaches a shell on a fleet box.
  test "the env file path is escaped" do
    ssh = FakeSsh.new(host_app_responses)
    DatabaseBackup.new(backup_with(env_file: "/home/deploy/odd name/.asdf-vars"), ssh: ssh).run!

    # The whole pipeline is escaped again for `bash -c`, so assert on behaviour
    # rather than a literal backslash count: the bare space must never survive.
    refute_includes ssh.dump_command, "odd name",
                    "an unescaped space would split the path into two arguments: #{ssh.dump_command}"
    assert_includes ssh.dump_command, "odd", "the path should still be there, escaped"
  end

  test "without an env file the behaviour is unchanged" do
    ssh = FakeSsh.new(host_app_responses)
    DatabaseBackup.new(backup_with(env_file: nil), ssh: ssh).run!

    refute_includes ssh.dump_command, "asdf-vars", "nothing to source"
    assert_includes ssh.dump_command, "DATABASE_URL"
    assert_includes ssh.dump_command, "pg_dump"
  end

  # A container-backed app must keep using the container even if someone fills in
  # an env file — the container is the more specific, more reliable source.
  test "a dedicated db container still wins over an env file" do
    ssh = FakeSsh.new(host_app_responses.merge("docker ps" => { success: true, output: "abc123" }))
    DatabaseBackup.new(backup_with(env_file: "/home/deploy/intellectaco/.asdf-vars"), ssh: ssh).run!

    assert ssh.dump_command.include?("pg_dumpall"), "should dump the container: #{ssh.dump_command}"
  end
end
