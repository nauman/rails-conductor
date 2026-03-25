require "json"
require "shellwords"

class CaddyClient
  class Error < StandardError; end

  ROUTE_ID_PREFIX = "conductor-route-".freeze
  DEFAULT_HTTP_SERVER = "srv0".freeze

  attr_reader :server

  def initialize(server, ssh_connection: nil)
    @server = server
    @ssh = ssh_connection || SshConnection.new(server)
  end

  def health_check
    fetch_config
    true
  rescue Error
    false
  end

  def fetch_config
    response = request_json("GET", "/config/")
    response.is_a?(Hash) ? response : {}
  end

  def snapshot_config
    {
      server_id: server.id,
      server_name: server.name,
      captured_at: Time.current.iso8601,
      config: fetch_config
    }
  end

  def fetch_managed_routes
    config = fetch_config
    http_servers(config).flat_map do |server_name, server_config|
      Array(server_config["routes"]).each_with_index.filter_map do |route, index|
        next unless managed_route?(route)

        summarize_route(route, server_name, index)
      end
    end
  end

  def upsert_route(route_definition)
    normalized = normalize_route_definition(route_definition)
    validate_route!(normalized)

    config = ensure_http_server(fetch_config, normalized[:server_name] || DEFAULT_HTTP_SERVER)
    server_name = normalized[:server_name] || resolve_http_server_name(config)
    routes = config.dig("apps", "http", "servers", server_name, "routes") || []
    route = build_route(normalized)

    existing_index = routes.index { |entry| entry["@id"] == route["@id"] }
    if existing_index
      routes[existing_index] = route
      action = "updated"
    else
      routes << route
      action = "created"
    end

    config["apps"]["http"]["servers"][server_name]["routes"] = routes
    load_config(config)

    summarize_route(route, server_name, existing_index || routes.length - 1).merge("action" => action)
  end

  def remove_route(route_id_or_domain)
    config = fetch_config
    server_name, route, index = locate_route(config, route_id_or_domain)
    raise Error, "Managed route not found: #{route_id_or_domain}" unless route

    routes = config["apps"]["http"]["servers"][server_name]["routes"]
    routes.delete_at(index)
    load_config(config)

    summarize_route(route, server_name, index).merge("action" => "removed")
  end

  def validate_route(route_definition)
    normalized = normalize_route_definition(route_definition)
    validate_route!(normalized)

    {
      valid: true,
      route_id: normalized[:route_id],
      upstream: normalize_upstream(normalized[:upstream]),
      upstream_type: upstream_type_for(normalized[:upstream])
    }
  rescue Error => e
    { valid: false, error: e.message }
  end

  def fetch_certificate_status(domain)
    route = fetch_managed_routes.find { |entry| entry["domain"] == domain }

    {
      domain: domain,
      status: route ? "managed" : "unknown",
      tls_enabled: route ? route["tls_enabled"] : nil,
      message: route ? "Route is managed by Conductor; certificate visibility is not fully implemented yet." : "No managed route found."
    }
  end

  private

  def http_servers(config)
    config.dig("apps", "http", "servers") || {}
  end

  def resolve_http_server_name(config)
    http_servers(config).keys.first || DEFAULT_HTTP_SERVER
  end

  def ensure_http_server(config, server_name)
    config = {} unless config.is_a?(Hash)
    config["apps"] ||= {}
    config["apps"]["http"] ||= {}
    config["apps"]["http"]["servers"] ||= {}
    config["apps"]["http"]["servers"][server_name] ||= {
      "listen" => [":80", ":443"],
      "routes" => []
    }
    config["apps"]["http"]["servers"][server_name]["routes"] ||= []
    config
  end

  def managed_route?(route)
    route.is_a?(Hash) && route["@id"].to_s.start_with?(ROUTE_ID_PREFIX)
  end

  def summarize_route(route, server_name, index)
    proxy = Array(route["handle"]).find { |entry| entry["handler"] == "reverse_proxy" } || {}
    upstream = Array(proxy["upstreams"]).first || {}
    host_match = Array(route["match"]).find { |entry| entry.key?("host") } || {}
    domain = Array(host_match["host"]).first

    {
      "route_id" => route["@id"],
      "domain" => domain,
      "upstream" => upstream["dial"],
      "upstream_type" => upstream["dial"].to_s.start_with?("unix//") ? "socket" : "tcp",
      "tls_enabled" => route.fetch("terminal", true),
      "server_name" => server_name,
      "route_index" => index
    }
  end

  def locate_route(config, route_id_or_domain)
    http_servers(config).each do |server_name, server_config|
      Array(server_config["routes"]).each_with_index do |route, index|
        next unless managed_route?(route)
        return [server_name, route, index] if route["@id"] == route_id_or_domain || route_domain(route) == route_id_or_domain
      end
    end

    [nil, nil, nil]
  end

  def route_domain(route)
    host_match = Array(route["match"]).find { |entry| entry.key?("host") } || {}
    Array(host_match["host"]).first
  end

  def normalize_route_definition(route_definition)
    route_definition = route_definition.to_h.transform_keys(&:to_sym)
    domain = route_definition[:domain].to_s.strip.downcase
    upstream = route_definition[:upstream].to_s.strip

    {
      domain: domain,
      upstream: upstream,
      route_id: route_definition[:route_id].presence || route_id_for(domain),
      server_name: route_definition[:server_name],
      tls_enabled: route_definition.key?(:tls_enabled) ? route_definition[:tls_enabled] : true
    }
  end

  def validate_route!(route_definition)
    raise Error, "Domain is required" if route_definition[:domain].blank?
    raise Error, "Upstream is required" if route_definition[:upstream].blank?
    raise Error, "Domain contains whitespace" if route_definition[:domain].match?(/\s/)

    upstream = route_definition[:upstream]
    tcp_like = upstream.include?(":") && !upstream.start_with?("/")
    socket_like = upstream.start_with?("/")

    raise Error, "Upstream must be host:port or an absolute socket path" unless tcp_like || socket_like
  end

  def build_route(route_definition)
    upstream = normalize_upstream(route_definition[:upstream])

    proxy_handler = {
      "@id" => "#{route_definition[:route_id]}-proxy",
      "handler" => "reverse_proxy",
      "upstreams" => [ { "dial" => upstream } ]
    }

    if upstream.start_with?("unix//")
      proxy_handler["headers"] = {
        "request" => {
          "set" => {
            "Host" => [ "localhost" ]
          }
        }
      }
    end

    {
      "@id" => route_definition[:route_id],
      "match" => [ { "host" => [ route_definition[:domain] ] } ],
      "handle" => [ proxy_handler ],
      "terminal" => route_definition[:tls_enabled]
    }
  end

  def normalize_upstream(upstream)
    upstream.start_with?("/") ? "unix//#{upstream}" : upstream
  end

  def upstream_type_for(upstream)
    upstream.start_with?("/") ? "socket" : "tcp"
  end

  def route_id_for(domain)
    "#{ROUTE_ID_PREFIX}#{domain.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")}"
  end

  def load_config(config)
    request_raw("POST", "/load", body: config)
    true
  end

  def request_json(method, path, body: nil)
    output = request_raw(method, path, body: body)
    return {} if output.blank?

    JSON.parse(output)
  rescue JSON::ParserError => e
    raise Error, "Invalid JSON from Caddy Admin API: #{e.message}"
  end

  def request_raw(method, path, body: nil)
    raise Error, "Server SSH is not configured" unless server.ssh_configured?

    result = @ssh.execute_with_status(build_curl_command(method, path, body: body))
    return result[:stdout].presence || result[:output].to_s if result[:success]

    raise Error, @ssh.error.presence || result[:stderr].presence || "Caddy request failed"
  end

  def build_curl_command(method, path, body: nil)
    url = "http://127.0.0.1:#{server.caddy_admin_port}#{path}"
    curl = +"curl -fsS -X #{Shellwords.escape(method)} #{Shellwords.escape(url)}"

    return curl unless body

    payload = Shellwords.escape(JSON.generate(body))
    "#{curl} -H #{Shellwords.escape('Content-Type: application/json')} --data-binary #{payload}"
  end
end
