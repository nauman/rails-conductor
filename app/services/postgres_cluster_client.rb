require "shellwords"

# Runs admin SQL on a Postgres cluster over SSH via `docker exec … psql`,
# mirroring CaddyClient's SSH-over-server pattern. Used to create/drop a
# per-app database + role on a shared cluster.
class PostgresClusterClient
  class Error < StandardError; end

  IDENTIFIER = /\A[a-z_][a-z0-9_]*\z/

  attr_reader :cluster

  def initialize(cluster, ssh_connection: nil)
    @cluster = cluster
    @ssh = ssh_connection || SshConnection.new(cluster.server)
  end

  def create_database(name:, username:, password:)
    validate_identifier!(name)
    validate_identifier!(username)

    exec_sql("CREATE ROLE #{username} LOGIN PASSWORD #{sql_quote(password)} CREATEDB")
    exec_sql("CREATE DATABASE #{name} OWNER #{username}")

    { "name" => name, "username" => username, "action" => "created" }
  end

  def drop_database(name:, username:)
    validate_identifier!(name)
    validate_identifier!(username)

    exec_sql("DROP DATABASE IF EXISTS #{name}")
    exec_sql("DROP ROLE IF EXISTS #{username}")

    { "name" => name, "username" => username, "action" => "dropped" }
  end

  private

  def exec_sql(sql)
    result = @ssh.execute_with_status(build_command(sql))
    return result[:stdout].to_s if result[:success]

    raise Error, (@ssh.error.presence || result[:stderr].presence || "psql command failed")
  end

  def build_command(sql)
    "docker exec -e PGPASSWORD=#{shell_quote(cluster.admin_password.to_s)} " \
      "#{Shellwords.escape(cluster.container_name)} " \
      "psql -U #{Shellwords.escape(cluster.admin_username)} -d postgres -v ON_ERROR_STOP=1 -tAc " \
      "#{shell_quote(sql)}"
  end

  # SQL string literal (doubles single quotes).
  def sql_quote(value)
    "'" + value.to_s.gsub("'", "''") + "'"
  end

  # Shell single-quote wrapper (keeps inner spaces literal).
  def shell_quote(value)
    "'" + value.to_s.gsub("'", "'\\''") + "'"
  end

  def validate_identifier!(value)
    return if value.to_s.match?(IDENTIFIER)

    raise Error, "Invalid SQL identifier: #{value.inspect}"
  end
end
