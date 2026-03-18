class ServerMetrics
  METRICS_COMMAND = <<~BASH
    echo "CPU:$(top -bn1 | grep 'Cpu(s)' | awk '{print $2}' | cut -d'%' -f1 2>/dev/null || echo '0')"
    echo "MEM_USED:$(free -m | awk 'NR==2{print $3}' 2>/dev/null || echo '0')"
    echo "MEM_TOTAL:$(free -m | awk 'NR==2{print $2}' 2>/dev/null || echo '0')"
    echo "DISK:$(df -h / | awk 'NR==2{print $5}' | tr -d '%' 2>/dev/null || echo '0')"
  BASH

  attr_reader :server, :ssh, :error

  def initialize(server)
    @server = server
    @ssh = SshConnection.new(server)
    @error = nil
  end

  def fetch
    return failure("SSH not configured") unless server.ssh_configured?

    output = ssh.execute(METRICS_COMMAND)

    unless ssh.success?
      return failure(ssh.error)
    end

    parse_metrics(output)
  end

  def fetch_and_update!
    metrics = fetch
    return false unless metrics

    server.update_metrics!(metrics)
    true
  rescue => e
    failure("Update failed: #{e.message}")
    false
  end

  def success?
    @error.nil?
  end

  private

  def parse_metrics(output)
    return failure("No output received") if output.blank?

    metrics = {}
    lines = output.to_s.lines.map(&:strip)

    lines.each do |line|
      case line
      when /^CPU:(.+)/
        metrics[:cpu_percent] = $1.to_f.round
      when /^MEM_USED:(.+)/
        metrics[:memory_used_mb] = $1.to_i
      when /^MEM_TOTAL:(.+)/
        metrics[:memory_total_mb] = $1.to_i
      when /^DISK:(.+)/
        metrics[:disk_percent] = $1.to_i
      end
    end

    if metrics.empty?
      return failure("Could not parse metrics")
    end

    metrics
  end

  def failure(message)
    @error = message
    nil
  end
end
