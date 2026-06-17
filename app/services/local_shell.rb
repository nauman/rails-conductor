require "open3"

# Runs a command as a local subprocess (in Conductor's own container), streaming
# combined stdout/stderr line-by-line to a block. Used by KamalDeployer now that
# Conductor is the Kamal *control machine* (it runs `kamal` locally rather than
# over SSH on the target). Injectable so deployers can be unit-tested.
class LocalShell
  Result = Struct.new(:success, :exit_code, :output, keyword_init: true) do
    def success? = success
  end

  # command: array form preferred (no shell parsing), e.g. ["git", "fetch"].
  # chdir/env optional. Yields each output line (chomped) as it arrives.
  def run(*command, chdir: nil, env: {})
    opts = {}
    opts[:chdir] = chdir if chdir
    output = +""
    status = nil

    Open3.popen2e(stringify(env), *command, opts) do |_stdin, out, wait_thr|
      out.each_line do |line|
        output << line
        yield line.chomp if block_given?
      end
      status = wait_thr.value
    end

    Result.new(success: status.success?, exit_code: status.exitstatus, output: output)
  rescue StandardError => e
    Result.new(success: false, exit_code: -1, output: e.message)
  end

  private

  def stringify(env)
    env.transform_keys(&:to_s).transform_values { |v| v.nil? ? nil : v.to_s }
  end
end
