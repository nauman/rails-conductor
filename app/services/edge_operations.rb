# The command boundary for operations that are commonly mistaken for raw Kamal
# commands. Kamal-proxy and Caddy have different control planes; dispatch here
# so Caddy never accidentally starts, stops, or reconfigures kamal-proxy.
class EdgeOperations
  class UnsupportedOperation < StandardError; end

  def initialize(app, caddy_client: nil, kamal_edge: nil, health_check: nil, user: nil, force: false)
    @app = app
    @caddy = caddy_client
    @kamal = kamal_edge
    @health_check = health_check
    @user = user
    @force = force
  end

  def proxy(action)
    case edge
    when "caddy"
      return caddy.fetch_managed_routes if action.to_sym == :inspect
      return live! if action.to_sym == :reconcile

      raise UnsupportedOperation, "Caddy edge owns proxy operations; use route inspection/reconciliation, not kamal proxy #{action}"
    when "kamal_proxy"
      require_kamal.proxy(action)
    else
      raise UnsupportedOperation, "cannot operate an undetected edge: #{edge.inspect}"
    end
  end

  # Stable Conductor operation vocabulary for UI/MCP callers. The callers do
  # not need to know whether the app is fronted by Caddy or kamal-proxy.
  def call(operation, message: nil)
    case operation.to_s
    when "inspect"
      proxy(:inspect)
    when "reconcile"
      proxy(:reconcile)
    when "redeploy"
      redeploy!
    when "maintenance"
      maintenance!(message: message.presence || "This application is temporarily unavailable for maintenance.")
    when "live"
      live!
    else
      raise UnsupportedOperation, "unknown edge operation #{operation.inspect}"
    end
  end

  def redeploy!
    deployment, status, = @app.start_deployment!(user: @user, force: @force)
    return status if status == :started || status == :already_running

    raise UnsupportedOperation, "redeploy blocked for #{@app.name} (deployment #{deployment&.id})"
  end

  def maintenance!(message: "This application is temporarily unavailable for maintenance.")
    ensure_domain!
    if edge == "caddy"
      result = caddy.maintenance(domain: @app.domain, message: message)
    else
      result = require_kamal.maintenance(message: message)
    end

    @app.update!(maintenance_mode: true, maintenance_message: message)
    result
  end

  def live!
    ensure_domain!
    if edge == "caddy"
      raise UnsupportedOperation, "refusing to restore #{@app.name}: app health is not current" unless healthy_for_edge?

      result = caddy.live(domain: @app.domain, upstream: caddy_upstream)
    else
      result = require_kamal.live
    end

    @app.update!(maintenance_mode: false, maintenance_message: nil)
    result
  end

  private

  def edge = @app.server&.edge_type

  def caddy
    @caddy ||= CaddyClient.new(@app.server)
  end

  def require_kamal
    @kamal || raise(UnsupportedOperation, "Kamal edge adapter is required for kamal-proxy operations")
  end

  def ensure_domain!
    raise UnsupportedOperation, "#{@app.name} has no domain to put into maintenance/live mode" if @app.domain.blank?
  end

  def caddy_upstream
    "127.0.0.1:#{@app.published_port}"
  end

  def healthy_for_edge?
    return @health_check.call if @health_check

    @app.container_status == "running" && @app.status == "running" && @app.status_fresh?
  end
end
