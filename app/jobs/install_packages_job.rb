class InstallPackagesJob < ApplicationJob
  queue_as :ops

  def perform(server_id, packages)
    server = Server.find_by(id: server_id)
    return unless server

    result = PackageInstaller.new(server, packages).install

    server.update!(
      last_package_install_status:   result.success? ? "succeeded" : "failed",
      last_package_install_packages: Array(packages).join(" ").first(255),
      last_package_install_log:      (result.output.presence || result.error).to_s.last(20_000),
      last_package_install_at:       Time.current
    )
  end
end
