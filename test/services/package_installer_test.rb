require "test_helper"

class PackageInstallerTest < ActiveSupport::TestCase
  # Records the command and returns a canned execute_with_status hash.
  class FakeSsh
    attr_reader :ran
    def initialize(result) = (@result = result)
    def execute_with_status(command)
      @ran = command
      @result
    end
  end

  setup do
    user = User.create!(email: "pi@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    @server = @org.servers.create!(name: "fleet", status: "online", ip_address: "10.0.0.9",
                                   ssh_key: @key, ssh_user: "deploy")
  end

  def ok_ssh(stdout = "done") = FakeSsh.new(success: true, exit_code: 0, stdout: stdout, stderr: "")

  test "parse_list splits whitespace and commas" do
    assert_equal %w[git curl build-essential], PackageInstaller.parse_list("git curl, build-essential")
  end

  test "installs valid packages via sudo apt-get and reports success" do
    ssh = ok_ssh("Setting up htop ...")
    res = PackageInstaller.new(@server, "htop ncdu", ssh: ssh).install

    assert res.success?
    assert_equal %w[htop ncdu], res.packages
    assert_includes ssh.ran, "sudo -n DEBIAN_FRONTEND=noninteractive apt-get update"
    assert_includes ssh.ran, "apt-get install -y htop ncdu"
    assert_includes res.output, "Setting up htop"
  end

  test "rejects shell-injection / invalid package names without running anything" do
    ssh = ok_ssh
    res = PackageInstaller.new(@server, "git; rm -rf /", ssh: ssh).install

    refute res.success?
    assert_match(/invalid package/i, res.error)
    assert_nil ssh.ran, "must not execute when a token is invalid"
  end

  test "accepts apt arch/version qualifiers" do
    res = PackageInstaller.new(@server, "libc6:amd64 nginx=1.18.0", ssh: ok_ssh).install
    assert res.success?
  end

  test "empty list is rejected" do
    res = PackageInstaller.new(@server, "   ", ssh: ok_ssh).install
    refute res.success?
    assert_match(/no packages/i, res.error)
  end

  test "a non-zero apt exit is surfaced as a failure with output" do
    ssh = FakeSsh.new(success: false, exit_code: 100, stdout: "", stderr: "E: Unable to locate package zzz")
    res = PackageInstaller.new(@server, "zzz", ssh: ssh).install

    refute res.success?
    assert_includes res.output, "Unable to locate package"
  end

  test "no ssh configured fails before executing" do
    @server.update_columns(ssh_key_id: nil)
    ssh = ok_ssh
    res = PackageInstaller.new(@server.reload, "git", ssh: ssh).install
    refute res.success?
    assert_nil ssh.ran
  end
end
