require "net/scp"
require "fileutils"

class SshConnection
  TIMEOUT = 10

  attr_reader :server, :error

  # `user:` overrides the login user (defaults to the server's ssh_user). Used by
  # provisioning orchestrations that must verify a freshly-created identity
  # (e.g. deploy) over SSH before committing to it.
  def initialize(server, user: nil)
    @server = server
    @login_user = user
    @error = nil
  end

  def login_user
    @login_user.presence || server.ssh_user_or_default
  end

  def test
    return failure("No SSH key configured") unless server.ssh_key.present?
    return failure("No IP address configured") unless server.ip_address.present?

    execute("echo 'connected'")
    success?
  end

  # Make remote output safe to interpolate into a UTF-8 string.
  #
  # Net::SSH delivers channel data as ASCII-8BIT. Appending it to a UTF-8 buffer
  # turns the buffer binary, and the failure surfaces far away — the moment that
  # output lands in a log line:
  #
  #   incompatible character encodings: UTF-8 and BINARY (ASCII-8BIT)
  #
  # A deploy died exactly there. `docker build` had SUCCEEDED; only the
  # handling of its progress output failed, so a good release was recorded as a
  # failed deploy. Short command output never trips it — only verbose non-ASCII
  # output like a build, which is why it survived every prior deploy.
  #
  # scrub, not delete: valid UTF-8 (a build's box-drawing characters) must
  # survive, and only genuinely invalid bytes are replaced.
  def self.utf8(data)
    return "" if data.nil?

    data.to_s.dup.force_encoding(Encoding::UTF_8).scrub("?")
  end

  def execute(command)
    @error = nil
    @output = nil

    return failure("No SSH key configured") unless server.ssh_key.present?
    return failure("No IP address configured") unless server.ip_address.present?

    begin
      Net::SSH.start(
        server.ip_address,
        login_user,
        **ssh_options
      ) do |ssh|
        @output = self.class.utf8(ssh.exec!(command))
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
      login_user,
      **ssh_options
    ) do |ssh|
      channel = ssh.open_channel do |ch|
        ch.exec(command) do |ch2, success|
          raise "Could not execute command on remote" unless success

          # utf8 at the point of accumulation — once a binary chunk lands in
          # the buffer the whole buffer is binary, and the error surfaces later.
          ch2.on_data { |_channel, data| stdout << self.class.utf8(data) }
          ch2.on_extended_data { |_channel, _type, data| stderr << self.class.utf8(data) }
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

  # Run several commands over ONE SSH session (a single connect), returning their
  # outputs in order. For batched read-probes (health/audit/storage/sudo in one
  # server-detail call) where a fresh connection per probe would blow the request
  # budget. On failure sets @error and returns an array of nils.
  def run_batch(commands)
    @error = nil
    unless server.ssh_key.present? && server.ip_address.present?
      failure("SSH not configured")
      return commands.map { nil }
    end

    outputs = []
    Net::SSH.start(server.ip_address, login_user, **ssh_options) do |ssh|
      commands.each { |c| outputs << self.class.utf8(ssh.exec!(c)) }
    end
    outputs
  rescue Net::SSH::AuthenticationFailed => e
    failure("Authentication failed: #{e.message}"); commands.map { nil }
  rescue => e
    failure("SSH error: #{e.message}"); commands.map { nil }
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
      login_user,
      **ssh_options
    ) do |ssh|
      channel = ssh.open_channel do |ch|
        ch.exec(script_body) do |ch2, success|
          raise "Could not execute script on remote" unless success

          ch2.on_data         { |_, data| block.call(:stdout, self.class.utf8(data)) if block }
          ch2.on_extended_data { |_, _, data| block.call(:stderr, self.class.utf8(data)) if block }
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
      login_user,
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

  # Upload CONTENT, not a command that writes content. The difference is the whole
  # point for a credential: anything passed through `exec` becomes a command string
  # on the remote host — visible in its process table and to anything recording
  # commands — whereas scp moves the bytes over the encrypted channel and they never
  # appear as an argument anywhere.
  #
  # `mode` is applied by scp at creation, so the file is never briefly world-readable
  # and no symlink planted at a predictable path is followed.
  # Restrict authentication to the stored key for the life of this block, so a
  # verification cannot pass on somebody else's credential.
  def with_only_stored_key
    previous = @strict_identity
    @strict_identity = true
    yield self
  ensure
    @strict_identity = previous
  end

  def upload_content(content, remote_path, mode: 0o600)
    @error = nil
    return false unless server.ssh_key.present? && server.ip_address.present?

    Net::SSH.start(server.ip_address, login_user, **ssh_options) do |ssh|
      ssh.scp.upload!(StringIO.new(content.to_s), remote_path, mode: mode)
    end
    true
  rescue Net::SSH::AuthenticationFailed => e
    failure("Authentication failed: #{e.message}")
    false
  rescue => e
    failure("Upload failed: #{e.message}")
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
      # Trust-on-first-use: record a host's key the first time, then REJECT if a
      # known host's key later changes (MITM protection) — instead of the old
      # `:never`, which trusted any presented key. Matches the Kamal policy.
      verify_host_key: :accept_new,
      user_known_hosts_file: known_hosts_path
    }

    if server.ssh_key.private_key.present?
      options[:key_data] = [ server.ssh_key.private_key ]

      if server.ssh_key.passphrase.present?
        options[:passphrase] = server.ssh_key.passphrase
      end
    end

    # ONLY THE STORED KEY, when the caller is proving that key works.
    #
    # By default Net::SSH will also offer agent identities and anything ~/.ssh/config
    # points at, so a connection can succeed on the OPERATOR's key while Conductor's
    # own is absent — and a check built on that proves nothing. Whenever the question
    # is "does the key we hold authenticate?", every other credential has to be off
    # the table or the answer is theatre.
    options.merge!(
      keys: [], keys_only: true, use_agent: false, config: false,
      auth_methods: [ "publickey" ]
    ) if @strict_identity

    options
  end

  # Managed known_hosts file for TOFU host-key verification. Overridable via
  # CONDUCTOR_KNOWN_HOSTS; defaults to the SSH user's ~/.ssh/known_hosts (the
  # dir is ensured so :accept_new can record a first-seen key).
  def known_hosts_path
    path = ENV["CONDUCTOR_KNOWN_HOSTS"].presence || File.expand_path("~/.ssh/known_hosts")
    FileUtils.mkdir_p(File.dirname(path))
    path
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
