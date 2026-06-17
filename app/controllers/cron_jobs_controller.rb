class CronJobsController < ApplicationController
  before_action :set_server

  # Create a scheduled job and install it into the server's crontab.
  def create
    @cron_job = @server.cron_jobs.new(cron_job_params.merge(organization: current_organization))

    if @cron_job.save
      install_and_redirect(@cron_job, notice: "Scheduled '#{@cron_job.name}'.")
    else
      redirect_to @server, alert: @cron_job.errors.full_messages.to_sentence
    end
  end

  # One-click: materialize a built-in maintenance script onto the server, then
  # schedule it as a cron job pointing at the installed path.
  def schedule_script
    script = Script.maintenance.built_in.find(params[:script_id])
    path = ScriptInstaller.new(@server).install(name: script.name, body: script.body)

    @cron_job = @server.cron_jobs.new(
      organization: current_organization, name: script.name.titleize,
      command: path, schedule: params[:schedule]
    )

    if @cron_job.save
      install_and_redirect(@cron_job, notice: "Scheduled '#{script.name}'.")
    else
      redirect_to @server, alert: @cron_job.errors.full_messages.to_sentence
    end
  rescue ScriptInstaller::Error => e
    redirect_to @server, alert: "Could not install the script on the server: #{e.message}"
  end

  # Enable/disable a job (comment/uncomment its crontab line).
  def update
    @cron_job = @server.cron_jobs.find(params[:id])
    @cron_job.update!(status: toggled_status(@cron_job))
    install_and_redirect(@cron_job, notice: "#{@cron_job.name} #{@cron_job.status}.")
  end

  # Remove the managed crontab block, then delete the record.
  def destroy
    @cron_job = @server.cron_jobs.find(params[:id])
    begin
      @cron_job.uninstall!
    rescue CrontabClient::Error => e
      flash[:alert] = "Removed the record, but the server reported: #{e.message}"
    end
    @cron_job.destroy
    redirect_to @server, notice: flash[:alert] ? nil : "Removed '#{@cron_job.name}'."
  end

  private

  def install_and_redirect(cron_job, notice:)
    cron_job.install!
    redirect_to @server, notice: notice
  rescue CrontabClient::Error => e
    redirect_to @server, alert: "Saved, but could not update the crontab: #{e.message}"
  end

  def toggled_status(cron_job)
    cron_job.enabled? ? "disabled" : "enabled"
  end

  def set_server
    @server = current_organization.servers.find(params[:server_id])
  end

  def cron_job_params
    params.require(:cron_job).permit(:name, :command, :schedule)
  end
end
