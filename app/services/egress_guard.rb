require "ipaddr"
require "resolv"
require "socket"

# Registering a server makes Conductor open SSH to an address a tenant typed
# (plan 02 § 5.4). For any org the operator did not vet, refuse everything that
# is not a public internet address, and anything that is the operator's own.
#
# Resolution happens on every connect (SshConnection#connect_address), and the
# caller dials the address returned here, never the hostname again — so a name
# that answers public at save time and private at connect time (DNS rebinding)
# is refused, and so is a name with ANY private answer among several.
module EgressGuard
  class Refused < StandardError; end

  BLOCKED_RANGES = %w[
    0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
    192.0.0.0/24 192.0.2.0/24 192.88.99.0/24 192.168.0.0/16 198.18.0.0/15
    198.51.100.0/24 203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ::/128 ::1/128 64:ff9b::/96 100::/64 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
  ].map { |cidr| IPAddr.new(cidr) }.freeze

  module_function

  # The address to dial, or raises Refused. `resolver` is injectable for tests.
  def resolve!(host, organization:, resolver: method(:system_resolve))
    host = host.to_s.strip
    raise Refused, "no address" if host.empty?

    addresses = literal?(host) ? [ host ] : Array(resolver.call(host))
    raise Refused, "#{host} does not resolve" if addresses.empty?

    parsed = addresses.map { |a| normalize(IPAddr.new(a)) }
    parsed.each do |ip|
      raise Refused, "#{host} resolves to a non-public address (#{ip})" if blocked?(ip)
      raise Refused, "#{host} resolves to an address Conductor reserves" if reserved?(ip, organization)
    end
    parsed.first.to_s
  rescue IPAddr::InvalidAddressError
    raise Refused, "#{host} is not a valid address"
  end

  def blocked?(ip)
    BLOCKED_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }
  end

  # The operator's servers and this host's own interfaces. Tenants may never
  # point Conductor at them, even when they are public (§ 4.1).
  def reserved?(ip, organization)
    reserved_addresses(organization).include?(ip.to_s)
  end

  def reserved_addresses(organization)
    vetted_org_ids = Organization.where(trust_level: "trusted")
                                 .where("signup_source IS NULL OR signup_source <> ?", Organization::OPEN_SIGNUP)
                                 .where.not(id: organization&.id).select(:id)
    stored = Server.where(organization_id: vetted_org_ids).or(Server.where(organization_id: nil))
                   .pluck(:ip_address).compact
    configured = ENV["CONDUCTOR_RESERVED_ADDRESSES"].to_s.split(",").map(&:strip)
    local = Socket.ip_address_list.map(&:ip_address)

    (stored + configured + local).filter_map do |a|
      literal?(a) ? normalize(IPAddr.new(a)).to_s : nil
    end.to_set
  end

  def literal?(host)
    IPAddr.new(host.to_s.delete_prefix("[").delete_suffix("]"))
    true
  rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
    false
  end

  # ::ffff:10.0.0.1 is 10.0.0.1 for every routing purpose.
  def normalize(ip)
    ip.ipv6? && ip.ipv4_mapped? ? ip.native : ip
  end

  def system_resolve(host)
    Resolv.getaddresses(host)
  end
end
