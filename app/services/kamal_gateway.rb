# Conductor's stable Kamal DSL. Callers depend on these domain operations, not
# Kamal's CLI grammar. Only this gateway is allowed to translate them into the
# version-specific KamalCommand syntax.
class KamalGateway
  def initialize(destination: nil)
    KamalCommand.assert_supported!
    @commands = KamalCommand.new(destination: destination)
  end

  def exec_live(command, interactive: false) = @commands.app_exec(command, interactive: interactive)
  def logs(lines:) = @commands.app_logs(lines: lines)
  def details = @commands.app_details
  def edge_proxy(action) = @commands.proxy(action)
  def maintenance(message: nil) = @commands.app_maintenance(message: message)
  def live = @commands.app_live
  def boot = @commands.app_boot
  def stop = @commands.app_stop
  def deploy = @commands.deploy
  def rollback(version) = @commands.rollback(version)
  def release_lock = @commands.lock_release
end
