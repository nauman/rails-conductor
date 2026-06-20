require "net/scp"

class SshConnection
  TIMEOUT = 10

  attr_reader :server, :error

  def initialize(server)
    @server = server
    @error = nil
  end

  def test
    return failure("No SSH key configured") unless server.ssh_key.present?
    return failure("No IP address configured") unless server.ip_address.present?

    execute("echo 'connected'")
    success?
  end

  def execute(command)
    @error = nil
    @output = nil

    return failure("No SSH key configured") unless server.ssh_key.present?
    return failure("No IP address configured") unless server.ip_address.present?

    begin
      Net::SSH.start(
        server.ip_address,
        server.ssh_user_or_default,
        **ssh_options
      ) do |ssh|
        @output = ssh.exec!(command)
      end
      @output
    rescue Net::SSH::AuthenticationFailed => e
      failure("Authentication failed: #{e.message}")
    rescue Errno::ECONNREFUSED => e
      failure("Connection refused: #{e.message}")
    rescue Errno::ETIMEDOUT, Net::SSH::ConnectionTimeout => e
      failure("Connection timed out: #{e.message}")
    rescue SocketError => e
      failure("Could not resolve hostname: #{e.message}")
    rescue => e
      failure("SSH error: #{e.message}")
    end
  end

  def execute_with_status(command)
    @error = nil
    @output = nil

    return failure_result("No SSH key configured") unless server.ssh_key.present?
    return failure_result("No IP address configured") unless server.ip_address.present?

    stdout = +""
    stderr = +""
    exit_code = nil

    Net::SSH.start(
      server.ip_address,
      server.ssh_user_or_default,
      **ssh_options
    ) do |ssh|
      channel = ssh.open_channel do |ch|
        ch.exec(command) do |ch2, success|
          raise "Could not execute command on remote" unless success

          ch2.on_data { |_channel, data| stdout << data }
          ch2.on_extended_data { |_channel, _type, data| stderr << data }
          ch2.on_request("exit-status") { |_channel, data| exit_code = data.read_long }
        end
      end
      channel.wait
      ssh.loop
    end

    exit_code ||= 0
    @output = stdout.presence || stderr.presence

    if exit_code.zero?
      { success: true, exit_code: exit_code, stdout: stdout, stderr: stderr, output: @output }
    else
      @error = stderr.presence || stdout.presence || "Remote command failed"
      { success: false, exit_code: exit_code, stdout: stdout, stderr: stderr, output: @output }
    end
  rescue Net::SSH::AuthenticationFailed => e
    failure_result("Authentication failed: #{e.message}")
  rescue Errno::ECONNREFUSED => e
    failure_result("Connection refused: #{e.message}")
  rescue Errno::ETIMEDOUT, Net::SSH::ConnectionTimeout => e
    failure_result("Connection timed out: #{e.message}")
  rescue SocketError => e
    failure_result("Could not resolve hostname: #{e.message}")
  rescue => e
    failure_result("SSH error: #{e.message}")
  end

  # Execute a script body with real-time streaming. Yields [:stdout/:stderr, data] chunks.
  # Returns { success: bool, exit_code: int }
  def execute_stream(script_body, &block)
    @error = nil
    exit_code = nil

    return failure("No SSH key configured") unless server.ssh_key.present?
    return failure("No IP address configured") unless server.ip_address.present?

    Net::SSH.start(
      server.ip_address,
      server.ssh_user_or_default,
      **ssh_options
    ) do |ssh|
      channel = ssh.open_channel do |ch|
        ch.exec(script_body) do |ch2, success|
          raise "Could not execute script on remote" unless success

          ch2.on_data         { |_, data| block.call(:stdout, data) if block }
          ch2.on_extended_data { |_, _, data| block.call(:stderr, data) if block }
          ch2.on_request("exit-status") { |_, data| exit_code = data.read_long }
        end
      end
      channel.wait
      ssh.loop
    end

    exit_code ||= 0
    { success: exit_code.zero?, exit_code: exit_code }
  rescue Net::SSH::AuthenticationFailed => e
    block.call(:stderr, "Authentication failed: #{e.message}\n") if block
    failure("Authentication failed: #{e.message}")
    { success: false, exit_code: 1 }
  rescue => e
    block.call(:stderr, "SSH error: #{e.message}\n") if block
    failure(e.message)
    { success: false, exit_code: 1 }
  end

  # Download a remote file to a local path via SCP (same key/auth as execute).
  # Returns true on success, false on failure (with @error set).
  def download(remote_path, local_path)
    @error = nil

    unless server.ssh_key.present?
      failure("No SSH key configured")
      return false
    end
    unless server.ip_address.present?
      failure("No IP address configured")
      return false
    end

    Net::SSH.start(
      server.ip_address,
      server.ssh_user_or_default,
      **ssh_options
    ) do |ssh|
      ssh.scp.download!(remote_path, local_path)
    end
    true
  rescue Net::SSH::AuthenticationFailed => e
    failure("Authentication failed: #{e.message}")
    false
  rescue => e
    failure("Download failed: #{e.message}")
    false
  end

  def success?
    @error.nil?
  end

  def output
    @output
  end

  private

  def ssh_options
    options = {
      port: server.ssh_port_or_default,
      timeout: TIMEOUT,
      non_interactive: true,
      verify_host_key: :never
    }

    if server.ssh_key.private_key.present?
      options[:key_data] = [server.ssh_key.private_key]

      if server.ssh_key.passphrase.present?
        options[:passphrase] = server.ssh_key.passphrase
      end
    end

    options
  end

  def failure(message)
    @error = message
    nil
  end

  def failure_result(message)
    @error = message
    { success: false, exit_code: 1, stdout: "", stderr: "", output: nil }
  end
end
