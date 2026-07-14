# Install one or more OS packages on a server (space/comma-separated in
# `packages`). Enqueues the job; the result streams to the server page.
class InstallServerPackagesTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    server = find_server(input)
    return Result.fail("Server not found: #{input['server_id'] || input['server_name']}") unless server

    packages = PackageInstaller.parse_list(input["packages"])
    return Result.fail("Provide one or more package names in 'packages'.") if packages.empty?

    server.update!(last_package_install_status: "running",
                   last_package_install_packages: packages.join(" ").first(255),
                   last_package_install_log: nil, last_package_install_at: Time.current)
    InstallPackagesJob.perform_later(server.id, packages)

    Result.ok({
      server:        server.name,
      packages:      packages,
      status:        "running",
      message:       "Installing #{packages.join(', ')} on #{server.name}.",
      _organization: server.organization
    })
  end
end
