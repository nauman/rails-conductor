require "shellwords"
require "base64"

# Materializes a Conductor Script's body onto a managed server as an executable
# file under /usr/local/bin, so cron (via CrontabClient) can invoke it by path.
# Mirrors the base64-pipe-over-SSH technique used by PostgresClusterClient.
class ScriptInstaller
  class Error < StandardError; end

  BIN_DIR = "/usr/local/bin".freeze

  attr_reader :server

  def initialize(server, ssh_connection: nil)
    @server = server
    @ssh = ssh_connection || SshConnection.new(server)
  end

  # Writes the script body to /usr/local/bin/conductor-<slug> (chmod +x) and
  # returns the absolute path.
  def install(name:, body:)
    path = remote_path(name)
    command = "echo #{Base64.strict_encode64(body.to_s)} | base64 --decode > #{Shellwords.escape(path)} " \
              "&& chmod +x #{Shellwords.escape(path)}"

    result = @ssh.execute_with_status(command)
    return path if result[:success]

    raise Error, (@ssh.error.presence || result[:stderr].presence || "Could not install script on server")
  end

  def remote_path(name)
    "#{BIN_DIR}/conductor-#{slugify(name)}"
  end

  private

  def slugify(name)
    name.to_s.strip.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-|-\z/, "")
  end
end
