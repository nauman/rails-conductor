require "test_helper"

class DatabasePullServiceTest < ActiveSupport::TestCase
  # SSH stub matching the slice of SshConnection that DatabasePullService uses.
  class FakeSsh
    attr_reader :commands, :downloads, :error
    def initialize(dump_success: true, size: "74007")
      @dump_success = dump_success
      @size = size
      @commands = []
      @downloads = []
      @output = nil
      @error = dump_success ? nil : "boom"
    end

    def execute_with_status(cmd)
      @commands << cmd
      { success: @dump_success, exit_code: @dump_success ? 0 : 1,
        stdout: "", stderr: @dump_success ? "" : "boom",
        output: @dump_success ? "" : "boom" }
    end

    def execute(cmd)
      @commands << cmd
      @output = @size
      @size
    end

    def output = @output
    def download(remote, local) = (@downloads << [remote, local]; true)
  end

  # LocalShell stub capturing the restore commands.
  class FakeShell
    attr_reader :runs
    def initialize(success: true)
      @success = success
      @runs = []
    end

    def run(*command, **_opts)
      @runs << command
      yield "ran: #{command.join(' ')}" if block_given?
      LocalShell::Result.new(success: @success, exit_code: @success ? 0 : 1, output: "")
    end
  end

  setup do
    user = User.create!(email: "dps@example.com")
    @org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "prod", status: "online", ip_address: "1.2.3.4", ssh_key: key)
  end

  def build_pull(attrs = {})
    DatabasePull.create!({
      server: @server, organization: @org, status: "pending",
      source_env_file: "/home/deploy/app/.asdf-vars",
      source_database_url_var: "DATABASE_URL"
    }.merge(attrs))
  end

  test "download-only pull dumps, downloads, records size, and succeeds" do
    pull = build_pull
    ssh = FakeSsh.new
    shell = FakeShell.new

    SshConnection.stub(:new, ssh) do
      assert DatabasePullService.new(pull, shell: shell).run
    end

    pull.reload
    assert_equal "success", pull.status
    assert_equal 74_007, pull.size_bytes
    assert pull.local_dump_path.present?
    assert_equal 1, ssh.downloads.size
    assert_empty shell.runs, "no local restore should run without a restore_target"
    # The dump command sources the env file and dumps the configured URL var.
    dump_cmd = ssh.commands.first
    assert_includes dump_cmd, ". '/home/deploy/app/.asdf-vars'"
    assert_includes dump_cmd, 'pg_dump -Fc --no-owner --no-acl "$DATABASE_URL"'
  end

  test "pull with restore_target runs dropdb, createdb, pg_restore locally" do
    pull = build_pull(restore_target: "int_app_development")
    ssh = FakeSsh.new
    shell = FakeShell.new

    SshConnection.stub(:new, ssh) do
      assert DatabasePullService.new(pull, shell: shell).run
    end

    assert_equal "success", pull.reload.status
    assert_equal 3, shell.runs.size
    assert_equal ["dropdb", "--if-exists", "int_app_development"], shell.runs[0]
    assert_equal ["createdb", "int_app_development"], shell.runs[1]
    assert_equal "pg_restore", shell.runs[2].first
    assert_includes shell.runs[2], "int_app_development"
  end

  test "remote dump failure fails the pull and skips download" do
    pull = build_pull
    ssh = FakeSsh.new(dump_success: false)
    shell = FakeShell.new

    SshConnection.stub(:new, ssh) do
      refute DatabasePullService.new(pull, shell: shell).run
    end

    assert_equal "failed", pull.reload.status
    assert_empty ssh.downloads
    assert_match(/Remote dump failed/, pull.log)
  end

  test "a fatal dropdb failure fails the restore" do
    pull = build_pull(restore_target: "int_app_development")
    ssh = FakeSsh.new
    shell = FakeShell.new(success: false)

    SshConnection.stub(:new, ssh) do
      refute DatabasePullService.new(pull, shell: shell).run
    end

    assert_equal "failed", pull.reload.status
    assert_equal 1, shell.runs.size, "should stop after the first fatal command"
  end
end
