require "socket"

# What a tenant may learn about the machine Conductor runs on (plan 02 § 4.3):
# its public hostname and SSH egress address, nothing else. Deploy logs and
# streamed output for an org the operator did not vet pass through here, so
# control-plane paths, the Docker host, this host's name and its interface
# addresses never reach the tenant. Vetted orgs see logs exactly as before.
module ControlPlaneRedactor
  MASK = "[conductor]".freeze

  module_function

  def redact(text, organization)
    return text unless organization&.untrusted_network_origin?

    out = text.to_s.gsub(/DOCKER_HOST=\S+/, "DOCKER_HOST=#{MASK}")
    secrets.each { |needle| out = out.gsub(needle, MASK) }
    out
  end

  def secrets
    paths = [ Rails.root.to_s, ENV["KAMAL_WORKSPACE"], ENV["HOME"], ENV["CONDUCTOR_KNOWN_HOSTS"] ]
    names = [ Socket.gethostname ]
    addresses = Socket.ip_address_list.map(&:ip_address).reject { |a| a.start_with?("127.", "::1") }
    (paths + names + addresses).compact.map(&:to_s).reject { |s| s.length < 4 || s == "/" }.uniq.sort_by { |s| -s.length }
  end
end
