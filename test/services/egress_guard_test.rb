require "test_helper"

# Plan 02 § 5.4 / § 9 step 4: server registration is an egress control.
class EgressGuardTest < ActiveSupport::TestCase
  setup do
    _user, @org = signed_up_tenant
  end

  def resolve(host, answers = nil)
    resolver = ->(_) { answers }
    EgressGuard.resolve!(host, organization: @org, resolver: resolver)
  end

  test "refuses loopback, metadata, private, CGNAT and IPv6 local literals" do
    %w[127.0.0.1 169.254.169.254 10.1.2.3 172.16.0.9 192.168.1.1 100.64.0.1 0.0.0.0
       ::1 fe80::1 fd00::1 ::ffff:10.0.0.1 ::ffff:127.0.0.1].each do |ip|
      assert_raises(EgressGuard::Refused, ip) { resolve(ip) }
    end
  end

  test "allows a public address and returns it to dial" do
    assert_equal "8.8.8.8", resolve("8.8.8.8")
    assert_equal "2606:4700:4700::1111", resolve("2606:4700:4700::1111")
  end

  test "a hostname is refused if ANY answer is private (round-robin rebinding)" do
    assert_raises(EgressGuard::Refused) { resolve("box.example.com", %w[8.8.8.8 10.0.0.5]) }
  end

  test "a hostname resolving to metadata is refused; the resolved public address is what gets dialled" do
    assert_raises(EgressGuard::Refused) { resolve("rebind.example.com", %w[169.254.169.254]) }
    assert_equal "1.1.1.1", resolve("ok.example.com", %w[1.1.1.1])
  end

  test "an unresolvable name is refused" do
    assert_raises(EgressGuard::Refused) { resolve("nothing.example.com", []) }
  end

  test "the operator's own servers are reserved even though they are public" do
    admin = User.create!(email: "ops@example.com", admin: true)
    operator = Organization.create_for(admin, name: "ops")
    operator.servers.create!(name: "edge", ip_address: "9.9.9.9", status: "online")
    assert_raises(EgressGuard::Refused) { resolve("9.9.9.9") }
    assert_raises(EgressGuard::Refused) { resolve("sneaky.example.com", %w[9.9.9.9]) }
  end

  test "CONDUCTOR_RESERVED_ADDRESSES reserves the control plane's egress address" do
    with_signup_env("CONDUCTOR_RESERVED_ADDRESSES" => "4.4.4.4, 5.5.5.5") do
      assert_raises(EgressGuard::Refused) { resolve("5.5.5.5") }
    end
  end

  test "saving a tenant server on a private address is refused at once" do
    server = @org.servers.new(name: "lan", ip_address: "192.168.0.10", status: "offline")
    refute server.valid?
    assert_match(/non-public/, server.errors[:ip_address].join)
  end

  test "vetted orgs keep private addresses (existing fleets on private networks)" do
    user = User.create!(email: "invited@example.com")
    org = Organization.create_for(user, name: "invited")
    assert org.servers.new(name: "lan", ip_address: "10.0.0.4", status: "online").valid?
  end
end

# The gate is applied where the connection is made, not only at save.
class SshConnectionTenantGateTest < ActiveSupport::TestCase
  setup do
    _user, @org = signed_up_tenant
    key = @org.ssh_keys.create!(name: "k", private_key: valid_private_key)
    @server = @org.servers.create!(name: "web-1", ip_address: "8.8.8.8", status: "online", ssh_key: key)
  end

  def dial_attempts
    hosts = []
    fake = ->(host, *_args, **_opts) { hosts << host; raise Errno::ECONNREFUSED }
    stub_ssh(fake) { yield }
    hosts
  end

  # NoRealSshInTests sits in front of Net::SSH.start; let it pass through to the
  # stub (which never dials — it records and refuses).
  def stub_ssh(fake, &block)
    with_signup_env("ALLOW_TEST_SSH" => "1") { Net::SSH.stub(:start, fake, &block) }
  end

  test "an unverified server is never dialled" do
    conn = SshConnection.new(@server)
    assert_empty(dial_attempts { conn.execute("true") })
    assert_match(/has not proved ownership/, conn.error)
  end

  test "the ownership probe may dial an unverified server" do
    assert_equal [ "8.8.8.8" ], dial_attempts { SshConnection.new(@server, ownership_probe: true).execute("true") }
  end

  test "an address that changed to private after save is refused at connect time and flagged" do
    @server.update_columns(ownership_verified_at: Time.current, ip_address: "10.0.0.7")
    conn = SshConnection.new(@server)
    assert_empty(dial_attempts { conn.execute("true") })
    assert_match(/non-public/, conn.error)
    assert_equal [ "egress_refused" ], @org.abuse_flags.pluck(:kind)
  end

  test "a hostname is dialled by its checked address, not re-resolved by Net::SSH" do
    @server.update_columns(ownership_verified_at: Time.current, ip_address: "box.example.com")
    Resolv.stub(:getaddresses, [ "1.0.0.1" ]) do
      assert_equal [ "1.0.0.1" ], dial_attempts { SshConnection.new(@server).execute("true") }
    end
  end

  test "20 SSH attempts an hour, then refused" do
    @server.update_columns(ownership_verified_at: Time.current)
    TenantLimits.store = ActiveSupport::Cache::MemoryStore.new
    freeze_time do
      attempts = dial_attempts { 21.times { SshConnection.new(@server).execute("true") } }
      assert_equal 20, attempts.size
    end
    assert_equal [ "ssh_attempts" ], @org.abuse_flags.pluck(:kind)
  ensure
    TenantLimits.store = nil
  end

  test "tenant connections never offer the control plane's agent or ssh config" do
    @server.update_columns(ownership_verified_at: Time.current)
    seen = nil
    fake = ->(_host, _user, **opts) { seen = opts; raise Errno::ECONNREFUSED }
    stub_ssh(fake) { SshConnection.new(@server).execute("true") }
    assert_equal false, seen[:use_agent]
    assert_equal false, seen[:config]
    assert_equal true, seen[:keys_only]
  end

  test "vetted orgs dial exactly as before" do
    user = User.create!(email: "invited@example.com")
    org = Organization.create_for(user, name: "invited")
    key = org.ssh_keys.create!(name: "k", private_key: valid_private_key)
    server = org.servers.create!(name: "lan", ip_address: "10.0.0.4", status: "online", ssh_key: key)
    assert_equal [ "10.0.0.4" ], dial_attempts { SshConnection.new(server).execute("true") }
  end
end
