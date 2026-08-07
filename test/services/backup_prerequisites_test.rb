require "test_helper"

# railslink's nightly backup dumped the database, gzipped it, and only then
# failed with `aws: command not found`. The prerequisite was checked implicitly,
# at the last possible moment, by the upload itself.
class BackupPrerequisitesTest < ActiveSupport::TestCase
  class FakeSsh
    attr_reader :commands

    # Stateful, because the code short-circuits: when apt fails it does not
    # re-check the CLI before falling back. Counting calls would encode that
    # implementation detail into the fake; modelling the BOX does not.
    #
    # `becomes_present_via` — which installer, if any, actually puts aws on PATH.
    def initialize(present:, becomes_present_via: nil, v2_succeeds: true)
      @present = present
      @via = becomes_present_via
      @v2_succeeds = v2_succeeds
      @commands = []
    end

    def execute_with_status(cmd)
      @commands << cmd
      if cmd.include?("awscli.amazonaws.com")
        @present = true if @v2_succeeds && @via == :v2
        return { success: @v2_succeeds, exit_code: @v2_succeeds ? 0 : 1, output: "",
                 stderr: @v2_succeeds ? "" : "curl: (6) could not resolve host" }
      end
      if cmd.include?("command -v aws")
        return { success: @present, exit_code: @present ? 0 : 1, output: "", stderr: "" }
      end
      { success: true, exit_code: 0, output: "", stderr: "" }
    end

    # The apt path runs through PackageInstaller, not this object, so the test's
    # FakeInstaller tells us when apt succeeded.
    def apt_installed! = (@present = true if @via == :apt)

    def tried_official_installer? = @commands.any? { |c| c.include?("awscli.amazonaws.com") }
  end

  class FakeInstaller
    attr_reader :calls

    def initialize(success: true, error: nil, ssh: nil)
      @success = success
      @error = error
      @ssh = ssh
      @calls = 0
    end

    def install
      @calls += 1
      @ssh&.apt_installed! if @success
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
    ssh = FakeSsh.new(present: false, becomes_present_via: :apt)
    installer = FakeInstaller.new(ssh: ssh)

    res = BackupPrerequisites.new(@server, ssh: ssh, installer: installer).ensure!

    assert res.ok?
    assert res.installed?, "the caller needs to know the box was changed"
    assert_equal 1, installer.calls
  end

  # Ubuntu 24.04 (noble) ships NO awscli package — `apt-cache policy awscli`
  # returns `Candidate: (none)` — so apt exits 100 and can never succeed there.
  # That is the box railslink runs on. apt failing must not be the end of it.
  test "when apt cannot provide the package, the official v2 installer is used" do
    ssh = FakeSsh.new(present: false, becomes_present_via: :v2)
    installer = FakeInstaller.new(success: false, error: "apt-get exited 100", ssh: ssh)

    res = BackupPrerequisites.new(@server, ssh: ssh, installer: installer).ensure!

    assert res.ok?
    assert res.installed?
    assert ssh.tried_official_installer?
    assert_match(/v2/, res.detail)
  end

  test "both routes failing reports both reasons, not a generic failure" do
    ssh = FakeSsh.new(present: false, becomes_present_via: nil, v2_succeeds: false)
    installer = FakeInstaller.new(success: false, error: "sudo: a password is required", ssh: ssh)

    res = BackupPrerequisites.new(@server, ssh: ssh, installer: installer).ensure!

    refute res.ok?
    assert_match(/sudo: a password is required/, res.detail)
    assert_match(/could not resolve host/, res.detail)
  end

  # An installer can exit 0 having installed nothing useful. Trusting it would
  # send the backup on to fail later with the exact error this class prevents.
  test "an installer succeeding while the CLI stays absent is a failure" do
    ssh = FakeSsh.new(present: false, becomes_present_via: nil)
    installer = FakeInstaller.new(success: true, ssh: ssh)

    res = BackupPrerequisites.new(@server, ssh: ssh, installer: installer).ensure!

    refute res.ok?
    assert_match(/still not on PATH/, res.detail)
    assert_equal 1, installer.calls, "must not retry apt in a loop"
  end
end
