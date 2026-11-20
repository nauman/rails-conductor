class AlertMailer < ApplicationMailer
  def backup_failed(backup)
    @backup = backup
    @server = backup.server || backup.app&.server

    mail(
      to: recipients_for(backup.organization || backup.app&.organization || @server&.organization),
      subject: "[Conductor] Backup failed: #{backup.bucket_name}"
    )
  end

  def deployment_failed(deployment)
    @deployment = deployment
    @app = deployment.app

    mail(
      to: recipients_for(@app&.organization),
      subject: "[Conductor] Deployment failed: #{@app.name}"
    )
  end

  def server_offline(server)
    @server = server

    mail(
      to: recipients_for(server.organization),
      subject: "[Conductor] Server offline: #{server.name}"
    )
  end

  private

  # Plan 02 § 5.5: a failure in an org the operator did not vet goes to THAT
  # org's owners, not the platform admin — otherwise every tenant's broken
  # deploy lands in the operator's inbox, and the mail names a tenant's
  # infrastructure to someone who is not its owner. Vetted orgs keep the old
  # behaviour (platform admins).
  def recipients_for(organization)
    return admin_emails unless organization&.untrusted_network_origin?

    organization.memberships.owner.joins(:user).pluck("users.email")
  end

  def admin_emails
    User.admins.pluck(:email)
  end
end
