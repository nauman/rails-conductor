class ProvisioningService
  def initialize(script_run)
    @script_run = script_run
    @server     = script_run.server
    @script     = script_run.script
  end

  def run
    @script_run.start!
    log("=== Starting: #{@script.name} on #{@server.name} (#{@server.ip_address}) ===\n")

    ssh = SshConnection.new(@server)

    result = ssh.execute_stream(@script.body) do |stream, data|
      prefix = stream == :stderr ? '[ERR] ' : ''
      log("#{prefix}#{data}")
    end

    log("\n=== Finished: #{result[:success] ? 'SUCCESS' : 'FAILED'} (exit #{result[:exit_code]}) ===\n")
    @script_run.finish!(success: result[:success])
    result[:success]
  rescue => e
    log("\n=== ERROR: #{e.message} ===\n")
    @script_run.finish!(success: false)
    false
  end

  private

  def log(line)
    @script_run.append_log(line)
  end
end
