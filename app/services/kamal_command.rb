require "shellwords"

# Compatibility boundary for Kamal's CLI grammar. Application services should
# ask this object for an operation instead of assembling Kamal flags themselves.
# When Kamal changes its command syntax, this is the primary integration point.
class KamalCommand
  # The floor is the GRAMMAR floor — the oldest CLI that answers every verb below.
  # Checked against the installed binary, not assumed: 2.10.1 supports `app exec`
  # with --reuse/--interactive, `app logs -n`, `app details`, `app maintenance
  # --message`, `app live`, `boot`, `stop`, `build push`, `deploy --skip-push`,
  # `rollback` and `lock release`.
  #
  # It reads 2.10.1 rather than 2.12.0 because nothing here needs 2.12, and asking
  # for it is not free: 2.12 refuses to deploy against a kamal-proxy older than
  # v0.9.2, and rebooting that shared proxy drops every host it routes. Raise this
  # in the same change that reboots the proxy, and only for a verb that needs it.
  MINIMUM_VERSION = Gem::Version.new("2.10.1")

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

  def app_exec(command, reuse: true, interactive: false, version: nil)
    flags = []
    flags << "--interactive" if interactive
    flags << "--reuse" if reuse
    flags << "--version=#{Shellwords.escape(version.to_s)}" if version.present?
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
  def build_push = finish("build push")
  def deploy(skip_push: false) = finish([ "deploy", ("--skip-push" if skip_push) ].compact.join(" "))
  def rollback(version) = finish("rollback #{Shellwords.escape(version)}")
  def lock_release = finish("lock release")

  private

  def finish(command)
    [ command, ("-d #{Shellwords.escape(@destination)}" if @destination.present?) ].compact.join(" ")
  end
end
