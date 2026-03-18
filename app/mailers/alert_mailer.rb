class AlertMailer < ApplicationMailer
  def backup_failed(backup)
    @backup = backup
    @server = backup.server || backup.app&.server

    mail(
      to: admin_emails,
      subject: "[Conductor] Backup failed: #{backup.bucket_name}"
    )
  end

  def deployment_failed(deployment)
    @deployment = deployment
    @app = deployment.app

    mail(
      to: admin_emails,
      subject: "[Conductor] Deployment failed: #{@app.name}"
    )
  end

  def server_offline(server)
    @server = server

    mail(
      to: admin_emails,
      subject: "[Conductor] Server offline: #{server.name}"
    )
  end

  private

  def admin_emails
    User.admins.pluck(:email)
  end
end
