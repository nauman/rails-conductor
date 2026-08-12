require "test_helper"

# Every page converted to the shared page_head/panel furniture, rendered once with real
# records. A view can only fail two ways here — a syntax error in the ERB, or a method the
# template invents — and both are silent until someone opens the page. A deployment detail
# page shipped broken for exactly that reason: no test ever rendered it.
class ConvertedPagesRenderTest < ActionDispatch::IntegrationTest
  # NOTE: not @app — ActionDispatch::IntegrationTest#app is the Rack application, and
  # assigning over it breaks every request in the class.
  setup do
    user = User.create!(email: "pages@example.com", admin: true)
    @org = Organization.create_for(user, name: "Pages")
    @org.update!(onboarded_at: Time.current)

    @key = @org.ssh_keys.create!(name: "fleet", private_key: valid_private_key)
    @server = @org.servers.create!(name: "box-1", ip_address: "203.0.113.10", ssh_key: @key,
                                   provider: "hetzner", region: "fsn1", status: "online",
                                   cpu_percent: 42, memory_used_mb: 2048, memory_total_mb: 8192,
                                   disk_percent: 61, metrics_updated_at: Time.current)
    @subject = @org.apps.create!(name: "Shop", slug: "shop", deploy_method: "docker", server: @server,
                             domain: "shop.example.com", status: "running", container_status: "running",
                             last_status_check_at: Time.current, repository_url: "https://github.com/acme/shop")
    @deployment = @subject.deployments.create!(status: "failed", started_at: 3.minutes.ago,
                                           completed_at: 1.minute.ago, commit_sha: "abc1234def",
                                           cause_class: "infrastructure", user: user)
    @credential = @org.credentials.create!(name: "R2", provider: "cloudflare", api_key: "k", api_secret: "s",
                                            active: true, verified_at: Time.current)
    @backup = @org.backups.create!(app: @app, server: @server, credential: @credential,
                                    provider: "cloudflare_r2", bucket_name: "pages-backups",
                                    schedule: "daily", retention_days: 14, enabled: true,
                                    status: "completed", last_run_at: 2.hours.ago)

    session = Passwordless::Session.create!(authenticatable: user)
    get "/users/sign_in/#{session.identifier}/#{session.token}"
  end

  test "every converted page renders" do
    paths = {
      "dashboard" => dashboard_path,
      "apps index" => apps_path,
      "app detail" => app_path(@subject),
      "servers index" => servers_path,
      "server detail" => server_path(@server),
      "backups index" => backups_path,
      "backup detail" => backup_path(@backup),
      "deployment detail" => deployment_path(@deployment),
      "credentials" => credentials_path,
      "ssh keys" => ssh_keys_path,
      "users" => users_path,
      "members" => members_path,
      "database clusters" => database_clusters_path,
      "database pulls" => database_pulls_path,
      "app logs" => logs_app_path(@subject),
      "app jobs" => jobs_app_path(@subject),
      "mcp tokens" => mcp_tokens_path,
      "integrations" => integrations_path,
      "new app" => new_app_path,
      "edit app" => edit_app_path(@subject),
      "new server" => new_server_path,
      "edit server" => edit_server_path(@server),
      "new backup" => new_backup_path,
      "edit backup" => edit_backup_path(@backup),
      "new credential" => new_credential_path,
      "edit credential" => edit_credential_path(@credential),
      "new ssh key" => new_ssh_key_path,
      "ssh key detail" => ssh_key_path(@key),
      "edit ssh key" => edit_ssh_key_path(@key),
      "scripts" => scripts_path,
      "organizations" => organizations_path,
      "admin organizations" => admin_organizations_path,
      "admin users" => admin_users_path,
      "admin mcp activity" => admin_mcp_calls_path,
      "server logs" => logs_server_path(@server)
    }

    paths.each do |name, path|
      get path
      assert_response :success, "#{name} (#{path}) did not render"
      # The shared header is the contract for a converted page: it always states a
      # situation in an h1, so a page that regressed to the old markup fails here too.
      assert_select "h1", { minimum: 1 }, "#{name} has no headline"
    end
  end
end
