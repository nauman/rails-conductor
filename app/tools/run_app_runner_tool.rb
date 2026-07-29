# Run a one-off Rails command inside an app's LIVE container over SSH — the
# non-interactive equivalent of `kamal console`. Either `ruby` (arbitrary Ruby
# via `bin/rails runner -`) or `task` (a bare rails/rake task name). kamal +
# docker apps only — native apps have no container to exec into.
#
# Sensitive: it runs real code against the running production app. A mutating
# script is destructive — confirm with the user first (the skill enforces this).
class RunAppRunnerTool
  include ActorScoped

  MAX_OUTPUT = 16_000
  # A bare rails/rake task: letters, digits, underscore, colon (namespaces). No
  # shell metacharacters — the task is interpolated straight into the command.
  TASK_RE = /\A[a-z0-9_][a-z0-9_:]*\z/i

  def initialize(user:)
    @user = user
  end

  def call(input)
    app = find_app(input)
    return Result.fail("App not found: #{input['app_id'] || input['app_name']}") unless app
    return Result.fail("App '#{app.name}' has no server with SSH configured.") unless app.server&.ssh_configured?
    unless app.kamal? || app.docker?
      return Result.fail("Runner is for kamal or docker apps (#{app.name} is #{app.deploy_method}). " \
                         "Native apps have no container — use the systemd unit directly.")
    end

    ruby = input["ruby"].to_s
    task = input["task"].to_s.strip
    if ruby.present? && task.present?
      return Result.fail("Pass either `ruby` or `task`, not both.")
    elsif ruby.blank? && task.blank?
      return Result.fail("Pass `ruby` (arbitrary Ruby, run via `rails runner`) or `task` (a bare rails/rake task).")
    end
    if task.present? && !task.match?(TASK_RE)
      return Result.fail("Invalid task '#{task}'. Give a bare rails/rake task name (e.g. db:migrate:status) — no arguments or shell.")
    end

    runner = RemoteRailsRunner.new(app)
    kind, ran = task.present? ? [ "task", task ] : [ "ruby", ruby ]
    res = task.present? ? runner.run_task(task) : runner.run(ruby)

    output = res.output.to_s
    no_container = res.exit_code == 3 || output.include?("NO_CONTAINER")

    message =
      if no_container
        "No running container found for #{app.name} — is it deployed and up? (sync_status to check)"
      elsif res.ok?
        "Ran #{kind} in #{app.name}'s container (exit #{res.exit_code})."
      else
        "#{kind} in #{app.name} exited #{res.exit_code || '?'} — see output."
      end

    Result.ok({
      app:           app.name,
      deploy_method: app.deploy_method,
      kind:          kind,
      ran:           ran.to_s[0, 400],
      ok:            res.ok? && !no_container,
      exit_code:     res.exit_code,
      no_container:  no_container,
      output:        truncate(output),
      message:       message,
      _organization: app.organization || app.server&.organization
    })
  end

  private

  def truncate(str)
    return str if str.length <= MAX_OUTPUT
    "#{str[0, MAX_OUTPUT]}\n… (truncated #{str.length - MAX_OUTPUT} more chars)"
  end
end
