# A CronJob had no app association — an app-scoped scheduled job (Heroku-Scheduler
# style) was just a raw command that docker-execs into the app container, so app
# jobs and host/server crons were structurally indistinguishable. Give it an
# optional app_id (app-scoped vs server-scoped) + the rails task it runs, so the
# distinction is real and the job is editable in place.
class AddAppAndTaskToCronJobs < ActiveRecord::Migration[8.1]
  def up
    add_reference :cron_jobs, :app, null: true, foreign_key: true
    add_column :cron_jobs, :task, :string

    # Backfill pre-existing app-scoped jobs: their command docker-execs into a
    # container carrying the app slug, and runs `bin/rails <task>`. Match the app
    # on the same server + extract the task. Best-effort; unmatched stay server-scoped.
    say_with_time "backfill cron_jobs.app_id from command" do
      CronJob.reset_column_information
      CronJob.where(app_id: nil).find_each do |job|
        app = App.where(server_id: job.server_id).detect { |a| a.slug.present? && job.command.to_s.include?(a.slug) }
        next unless app
        task = job.command.to_s[/bin\/rails\s+([a-zA-Z0-9_:.\-]+)/, 1]
        job.update_columns(app_id: app.id, task: task)
      end
    end
  end

  def down
    remove_column :cron_jobs, :task
    remove_reference :cron_jobs, :app, foreign_key: true
  end
end
