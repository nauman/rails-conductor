require "test_helper"

# Proof of control (plan 02 § 5.4). The probe is shell, so it is RUN against real
# authorized_keys files — empty, missing, unterminated, CRLF, a near-miss nonce.
class ServerOwnershipTest < ActiveSupport::TestCase
  NONCE = "0123456789abcdef0123456789abcdef".freeze
  LINE = "ssh-ed25519 AAAAC3Nza conductor-verify-#{NONCE}".freeze

  def probe(authorized_keys)
    in_a_sandbox do |home|
      FileUtils.mkdir_p(File.join(home, ".ssh"))
      File.write(File.join(home, ".ssh", "authorized_keys"), authorized_keys) unless authorized_keys.nil?
      run_shell(ServerOwnership.probe_command(NONCE), env: { "HOME" => home })
    end
  end

  test "prints the marker when the line is installed" do
    out, _err, status = probe("ssh-rsa AAAA other\n#{LINE}\n")
    assert_equal 0, status
    assert_equal "conductor-verify-#{NONCE}\n", out
  end

  test "finds a last line with no newline, and a CRLF file" do
    assert_equal 0, probe("ssh-rsa AAAA other\n#{LINE}")[2]
    assert_equal 0, probe("ssh-rsa AAAA other\r\n#{LINE}\r\n")[2]
  end

  test "prints nothing and fails for a missing file, an empty file, or another nonce" do
    [ nil, "", "ssh-ed25519 AAAA conductor-verify-#{NONCE.reverse}\n" ].each do |content|
      out, _err, status = probe(content)
      assert_equal "", out
      refute_equal 0, status
    end
  end

  test "fails closed when grep is absent" do
    out, _err, status = run_shell_with_empty_path(ServerOwnership.probe_command(NONCE))
    assert_equal "", out
    refute_equal 0, status
  end

  test "verify! marks the server verified only on the exact nonce" do
    _u, org = signed_up_tenant
    key = org.ssh_keys.create!(name: "k", private_key: valid_private_key)
    server = org.servers.create!(name: "web-1", ip_address: "8.8.8.8", status: "offline", ssh_key: key)
    nonce = ServerOwnership.issue_nonce!(server)

    refute ServerOwnership.new(server, ssh: FakeOwnershipSsh.new("", error: "Authentication failed")).verify!.ok?
    refute server.reload.ownership_verified?

    assert ServerOwnership.new(server, ssh: FakeOwnershipSsh.new("conductor-verify-#{nonce}\n")).verify!.ok?
    assert server.reload.ownership_verified?
  end

  test "the authorized_keys line carries the nonce as its comment" do
    _u, org = signed_up_tenant
    key = org.ssh_keys.create!(name: "k", private_key: valid_private_key)
    server = org.servers.create!(name: "web-1", ip_address: "8.8.8.8", status: "offline", ssh_key: key)
    nonce = ServerOwnership.issue_nonce!(server)
    assert_match(/\Assh-ed25519 \S+ conductor-verify-#{nonce}\z/, ServerOwnership.authorized_keys_line(server))
  end
end
