require "shellwords"

# Compatibility boundary for Kamal's CLI grammar. Application services should
# ask this object for an operation instead of assembling Kamal flags themselves.
# When Kamal changes its command syntax, this is the primary integration point.
class KamalCommand
  MINIMUM_VERSION = Gem::Version.new("2.12.0")

  def self.installed_version
    Gem.loaded_specs.fetch("kamal").version
  end

  def self.assert_supported!
    version = installed_version
    raise "Kamal #{MINIMUM_VERSION} or newer is required (found #{version})" if version < MINIMUM_VERSION

    version
  end

  def initialize(destination: nil)
    @destination = destination
  end

  def app_exec(command, reuse: true, interactive: false)
    flags = []
    flags << "--interactive" if interactive
    flags << "--reuse" if reuse
    finish([ "app", "exec", *flags, Shellwords.escape(command) ].join(" "))
  end

  def app_logs(lines:)
    finish("app logs -n #{lines.to_i}")
  end

  def app_details = finish("app details")

  def proxy(action) = finish("proxy #{Shellwords.escape(action.to_s)}")

  def app_maintenance(message: nil)
    suffix = message.present? ? " --message #{Shellwords.escape(message)}" : ""
    finish("app maintenance#{suffix}")
  end

  def app_live = finish("app live")
  def app_boot = finish("app boot")
  def app_stop = finish("app stop")
  def deploy = finish("deploy")
  def rollback(version) = finish("rollback #{Shellwords.escape(version)}")
  def lock_release = finish("lock release")

  private

  def finish(command)
    [ command, ("-d #{Shellwords.escape(@destination)}" if @destination.present?) ].compact.join(" ")
  end
end
