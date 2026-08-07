require "test_helper"

# railslink's nightly backup dumped the database, gzipped it, and only then
# failed with `aws: command not found`. The prerequisite was checked implicitly,
# at the last possible moment, by the upload itself.
class BackupPrerequisitesTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    def initialize(present:, present_after_install: nil)
      @present = present
      @after = present_after_install.nil? ? present : present_after_install
      @commands = []
      @checks = 0
    end

    def execute_with_status(cmd)
      @commands << cmd
      if cmd.include?("command -v aws")
        @checks += 1
        ok = @checks == 1 ? @present : @after
        return { success: ok, exit_code: ok ? 0 : 1, output: "", stderr: "" }
      end
      { success: true, exit_code: 0, output: "", stderr: "" }
    end
  end

  class FakeInstaller
    attr_reader :calls

    def initialize(success: true, error: nil)
      @success = success
      @error = error
      @calls = 0
    end

    def install
      @calls += 1
      PackageInstaller::Result.new(success: @success, output: "", error: @error, packages: [ "awscli" ])
    end
  end

  setup do
    user = User.create!(email: "prereq@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @server = @org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.1")
  end

  test "a box that already has the CLI is left alone" do
    installer = FakeInstaller.new
    res = BackupPrerequisites.new(@server, ssh: FakeSsh.new(present: true), installer: installer).ensure!

    assert res.ok?
    refute res.installed?, "must not install over a working CLI"
    assert_equal 0, installer.calls
  end

  test "a missing CLI is installed and the box becomes ready" do
    installer = FakeInstaller.new
    ssh = FakeSsh.new(present: false, present_after_install: true)

    res = BackupPrerequisites.new(@server, ssh: ssh, installer: installer).ensure!

    assert res.ok?
    assert res.installed?, "the caller needs to know the box was changed"
    assert_equal 1, installer.calls
  end

  test "a failed install reports the apt error, not a generic failure" do
    installer = FakeInstaller.new(success: false, error: "sudo: a password is required")
    res = BackupPrerequisites.new(@server, ssh: FakeSsh.new(present: false), installer: installer).ensure!

    refute res.ok?
    assert_match(/sudo: a password is required/, res.detail)
  end

  # apt can exit 0 having installed nothing useful. Trusting it would send the
  # backup on to fail later with the exact error this class exists to prevent.
  test "apt succeeding but the CLI still being absent is a failure" do
    installer = FakeInstaller.new(success: true)
    ssh = FakeSsh.new(present: false, present_after_install: false)

    res = BackupPrerequisites.new(@server, ssh: ssh, installer: installer).ensure!

    refute res.ok?
    assert_match(/still not on PATH/, res.detail)
    assert_equal 1, installer.calls, "must not retry in a loop"
  end
end
