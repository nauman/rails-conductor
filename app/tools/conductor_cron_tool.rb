# Scheduled jobs (cron) — the Heroku-Scheduler equivalent, over Conductor's
# CronJob backend (installs managed entries into the server's crontab). Flat
# action enum:
#   schedule    — create + install a job. For an app: app_id/app_name + task
#                 (a rails task like "slack:sync") runs it in the app's container
#                 on a schedule. For a server: server_id + command (raw).
#   list        — managed cron jobs (all visible, or filter by server_id/app_id).
#   remove      — uninstall from the crontab + delete (cron_job_id).
#   set_enabled — enable/disable a job (comments/uncomments its crontab line).
class ConductorCronTool
  include ActorScoped

  TASK_RE = /\A[a-zA-Z0-9_:.\-]+\z/

  DEFINITION = {
    name: "conductor_cron",
    description: "Scheduled jobs (cron) on a server — the Heroku-Scheduler equivalent. Set `action` to one of: " \
      "schedule (create + install a job — name + schedule ('every hour', 'daily at 3am', or raw '0 * * * *') PLUS either app_id/app_name + task (a rails task like slack:sync, run in the app's container) OR server_id + command (raw)), " \
      "list (managed cron jobs — all visible, or filter by server_id/app_id), " \
      "remove (uninstall from the crontab + delete — cron_job_id), " \
      "set_enabled (enable/disable a job — cron_job_id + enabled). Mutating (except list) — installs real crontab entries; confirm.",
    input_schema: {
      type: "object",
      properties: {
        action:      { type: "string", enum: %w[schedule list remove set_enabled], description: "Which cron operation" },
        app_id:      { type: "integer", description: "schedule/list: target app (its server + container)" },
        app_name:    { type: "string",  description: "schedule/list: target app by name" },
        server_id:   { type: "integer", description: "schedule/list: target server (raw command / filter)" },
        server_name: { type: "string",  description: "schedule: target server by name" },
        name:        { type: "string",  description: "schedule: human name for the job" },
        schedule:    { type: "string",  description: "schedule: 'every hour', 'daily at 3am', or raw cron '0 * * * *'" },
        task:        { type: "string",  description: "schedule (app): a rails task to run, e.g. slack:sync" },
        command:     { type: "string",  description: "schedule (server): the raw command to run" },
        cron_job_id: { type: "integer", description: "remove/set_enabled: the cron job id" },
        enabled:     { type: "boolean", description: "set_enabled: true=enable, false=disable" }
      },
      required: %w[action]
    }
  }.freeze

  def initialize(user:)
    @user = user
  end

  def call(input)
    case input["action"]
    when "schedule"    then schedule(input)
    when "list"        then list(input)
    when "remove"      then remove(input)
    when "set_enabled" then set_enabled(input)
    else Result.fail("Missing or unknown action. Set action to one of: schedule, list, remove, set_enabled.")
    end
  end

  private

  def schedule(input)
    name     = input["name"].to_s.strip
    schedule = input["schedule"].to_s.strip
    return Result.fail("name and schedule are required.") if name.blank? || schedule.blank?

    app = find_app(input)
    if app
      task = input["task"].to_s.strip
      return Result.fail("task is required (a rails task name like slack:sync).") if task.blank?
      return Result.fail("Invalid task name '#{task}'.") unless task.match?(TASK_RE)
      return Result.fail("#{app.name} has no server to schedule on.") unless app.server

      server  = app.server
      command = app.scheduled_command(task)
      org     = app.organization || server.organization
    else
      server = find_server(input)
      return Result.fail("Pass app_id/app_name (+ task) or server_id (+ command).") unless server
      command = input["command"].to_s.strip
      return Result.fail("command is required when scheduling directly on a server.") if command.blank?
      org = server.organization
    end

    job = server.cron_jobs.new(organization: org, name: name, command: command, schedule: schedule)
    return Result.fail(job.errors.full_messages.to_sentence) unless job.save

    begin
      job.install!
    rescue => e
      job.destroy
      return Result.fail("Saved but couldn't install into the crontab: #{e.message}")
    end

    Result.ok(job_view(job).merge(message: "Scheduled '#{job.name}' on #{server.name} (#{job.cron_expression}).", _organization: org))
  end

  def list(input)
    scope = CronJob.where(server_id: visible_servers.select(:id))
    if (s = find_server(input))
      scope = scope.where(server_id: s.id)
    elsif (a = find_app(input))
      scope = scope.where(server_id: a.server_id)
    end
    Result.ok({ cron_jobs: scope.order(:server_id, :name).map { |j| job_view(j) } })
  end

  def remove(input)
    job = find_job(input)
    return Result.fail("Cron job not found. Pass a valid cron_job_id.") unless job

    name = job.name
    server = job.server&.name
    org = job.organization
    begin
      job.uninstall!
    rescue => e
      return Result.fail("Couldn't remove from the crontab: #{e.message}")
    end
    job.destroy
    Result.ok({ removed: true, name: name, server: server, _organization: org })
  end

  def set_enabled(input)
    job = find_job(input)
    return Result.fail("Cron job not found. Pass a valid cron_job_id.") unless job

    job.update!(status: input["enabled"] == false ? "disabled" : "enabled")
    begin
      job.install! # upsert re-writes the block commented/uncommented per enabled?
    rescue => e
      return Result.fail("Saved but couldn't update the crontab: #{e.message}")
    end
    Result.ok(job_view(job).merge(_organization: job.organization))
  end

  def find_job(input)
    return nil if input["cron_job_id"].blank?
    CronJob.where(server_id: visible_servers.select(:id)).find_by(id: input["cron_job_id"])
  end

  def job_view(job)
    {
      id: job.id, name: job.name, server: job.server&.name,
      schedule: job.schedule, cron: job.cron_expression,
      enabled: job.enabled?, command: job.command
    }
  end
end
