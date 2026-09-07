# RUN THE COMMAND. DO NOT READ IT.
#
# Every shell defect in this codebase's history was invisible in review and obvious
# in execution. A sample, all of which passed code review and a green suite:
#
#   * `awk "NF && !seen[$0]++"` — Ruby consumed the backslash, the inner shell
#     expanded $0 before awk ran, and the dedupe key became a constant. Three keys
#     went in, one came out, exit status 0.
#   * `sort -u` deduplicated by REORDERING, and sshd uses the first matching entry —
#     so it could promote a less-restricted key above a more-restricted one.
#   * `[ -n "$(tail -c 1 F)" ]` treated a FAILED tail as "ends in a newline", so the
#     next append spliced a key onto the previous one and broke both.
#
# What they have in common: asserting on the command STRING would have passed. Only
# executing it against a real file showed the behaviour.
#
# So the rule is: if a change renders shell, a test renders that shell and runs it,
# over the inputs that matter — empty, missing, unterminated, permission-denied,
# tool-absent. Assert the FILE, not the command.
module ShellBehaviour
  # Runs `script` in a throwaway directory and yields it, so assertions look at what
  # the filesystem actually holds afterwards.
  #
  #   in_a_sandbox(files: { "ak" => "ssh-rsa EXISTING nonewline" }) do |dir|
  #     run_shell(script_for(dir))
  #     assert_equal 2, File.read("#{dir}/ak").lines.count
  #   end
  def in_a_sandbox(files: {})
    dir = Dir.mktmpdir("shell-behaviour")
    files.each do |name, content|
      path = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, content)
    end
    yield dir
  ensure
    FileUtils.remove_entry(dir) if dir && File.exist?(dir)
  end

  # Returns [stdout, stderr, exit_status]. Uses /bin/sh, not bash: the remote hosts
  # run the command through `sh -c`, and a bashism that works locally is a defect
  # that only appears in production.
  def run_shell(script, env: {})
    stdout, stderr, status = Open3.capture3(env, "/bin/sh", "-c", script)
    [ stdout, stderr, status.exitstatus ]
  end

  # A tool made unavailable, to prove a guard fails CLOSED rather than open. The
  # tail-guard defect above only appeared this way.
  def without_command(&block)
    run_shell_with_empty_path(&block)
  end

  def run_shell_with_empty_path(script)
    run_shell(script, env: { "PATH" => "/nonexistent" })
  end
end
