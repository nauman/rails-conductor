require "test_helper"

class ServerStorageTest < ActiveSupport::TestCase
  class FakeSsh
    def initialize(output:, success: true, error: nil)
      @output = output; @success = success; @error = error
    end
    def execute(_cmd) = @output
    def success? = @success
    def error = @error
  end

  setup do
    user = User.create!(email: "st@example.com")
    org = Organization.create_for(user, name: "Acme")
    key = SshKey.create!(name: "k", private_key: valid_private_key, organization: org)
    @server = org.servers.create!(name: "box", status: "online", ip_address: "10.0.0.9", ssh_key: key)
  end

  PROBE_OUTPUT = <<~OUT
    ===DF===
    /dev/sda1 105089331200 30926749696 68785936384 32 /
    ===INODES===
    /dev/sda1 6553600 412000 6141600 7 /
    ===SWAP===
    2147483648 268435456 1879048192
    ===MEM===
    24696061952 3221225472 20000000000
    ===TOPDIRS===
    18000000000 /var
    12000000000 /var/lib/docker
    4000000000 /home
    2000000000 /usr
  OUT

  test "parses filesystems, swap, memory, inodes, and largest dirs" do
    result = ServerStorage.new(@server, ssh: FakeSsh.new(output: PROBE_OUTPUT)).load

    assert result.ok?, result.error
    root = result.mounts.find { |m| m.mount == "/" }
    assert_equal "/dev/sda1", root.filesystem
    assert_equal 32, root.percent
    assert_equal 105089331200, root.size

    assert_equal 2147483648, result.swap[:total]
    assert_equal 13, result.swap[:percent]
    assert_equal 24696061952, result.memory[:total]

    assert_equal "/", result.inodes.first.mount
    assert_equal "/var", result.top_dirs.first.path
    assert_equal 18000000000, result.top_dirs.first.bytes
    assert_operator result.top_dirs.first.bytes, :>, result.top_dirs.last.bytes
  end

  test "no swap configured yields nil swap" do
    out = PROBE_OUTPUT.sub("2147483648 268435456 1879048192", "0 0 0")
    result = ServerStorage.new(@server, ssh: FakeSsh.new(output: out)).load
    assert_nil result.swap
  end

  test "SSH failure surfaces an error" do
    result = ServerStorage.new(@server, ssh: FakeSsh.new(output: "", success: false, error: "boom")).load
    assert_not result.ok?
    assert_equal "boom", result.error
  end
end
