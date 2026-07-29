require "test_helper"

# The fleet mock's central argument: one app suffocating on 2 cores beside a 64GB box at 3%
# is invisible unless the dashboard says it out loud. This is the panel that earns the
# app-transfer feature, so it has to fire only when the move is genuinely worth making.
class FleetCapacityTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(email: "cap@example.com")
    @org = Organization.create_for(@user, name: "Acme")
    @org.update!(onboarded_at: Time.current)
    @key = SshKey.create!(name: "k", private_key: valid_private_key, organization: @org)
    session_record = Passwordless::Session.create!(authenticatable: @user)
    get "/users/sign_in/#{session_record.to_param}/#{session_record.token}"
  end

  def server(name:, cpu:, mem_total:, ip:)
    @org.servers.create!(name: name, status: "online", ip_address: ip, ssh_key: @key,
                         ssh_user: "deploy", cpu_percent: cpu, memory_total_mb: mem_total,
                         memory_used_mb: (mem_total * 0.1).to_i, disk_percent: 20,
                         metrics_updated_at: 1.minute.ago)
  end

  test "a straining box beside an idle one is called out" do
    strained = server(name: "small-box", cpu: 63, mem_total: 7941, ip: "10.0.0.1")
    server(name: "big-box", cpu: 3, mem_total: 64215, ip: "10.0.0.2")

    get dashboard_path
    assert_match(/out of room/i, response.body)
    assert_match(/#{strained.name}/, response.body)
  end

  test "two busy boxes are not an imbalance — there is nowhere to move to" do
    server(name: "busy-a", cpu: 70, mem_total: 8000, ip: "10.0.1.1")
    server(name: "busy-b", cpu: 65, mem_total: 8000, ip: "10.0.1.2")

    get dashboard_path
    refute_match(/out of room/i, response.body, "moving work between two full boxes helps nobody")
  end

  test "an idle fleet says nothing" do
    server(name: "calm-a", cpu: 4, mem_total: 32000, ip: "10.0.2.1")
    server(name: "calm-b", cpu: 6, mem_total: 32000, ip: "10.0.2.2")

    get dashboard_path
    refute_match(/out of room/i, response.body)
  end

  test "stale metrics never raise a capacity claim" do
    s = server(name: "stale-box", cpu: 90, mem_total: 4000, ip: "10.0.3.1")
    s.update_columns(metrics_updated_at: 2.hours.ago)
    server(name: "fresh-idle", cpu: 2, mem_total: 64000, ip: "10.0.3.2")

    get dashboard_path
    refute_match(/out of room/i, response.body,
                 "a number from two hours ago is not evidence of anything now")
  end
end
