require "test_helper"

# Plan 02 § 5.5 / § 9 step 10: a tenant's failure mails the tenant's owners, not
# the platform admin. Vetted orgs keep the old recipients.
class TenantAlertScopingTest < ActionMailer::TestCase
  setup do
    User.create!(email: "ops@example.com", admin: true)
    @owner, @org = signed_up_tenant(email: "owner@tenant.example")
    @org.add_member(User.create!(email: "viewer@tenant.example"), role: :member)
    @server = @org.servers.create!(name: "web-1", ip_address: "8.8.8.8", status: "offline")
  end

  test "server offline goes to the tenant's owners only" do
    assert_equal [ "owner@tenant.example" ], AlertMailer.server_offline(@server).to
  end

  test "deployment failure goes to the tenant's owners only" do
    app = @org.apps.create!(name: "a", slug: "tenant-a", deploy_method: "docker", repository_url: "https://github.com/x/y.git")
    assert_equal [ "owner@tenant.example" ], AlertMailer.deployment_failed(app.deployments.create!(status: "failed")).to
  end

  test "backup failure goes to the tenant's owners only" do
    backup = @org.backups.create!(provider: "aws_s3", bucket_name: "tenant-bucket", enabled: true)
    assert_equal [ "owner@tenant.example" ], AlertMailer.backup_failed(backup).to
  end

  test "a vetted org still alerts the platform admins" do
    user = User.create!(email: "invited@example.com")
    org = Organization.create_for(user, name: "invited")
    server = org.servers.create!(name: "box", ip_address: "10.0.0.1", status: "offline")
    assert_equal [ "ops@example.com" ], AlertMailer.server_offline(server).to
  end
end
