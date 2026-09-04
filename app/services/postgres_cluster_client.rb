require "shellwords"
require "base64"

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
    validate_identifier!(username, role: true)

    exec_sql("CREATE ROLE #{username} LOGIN PASSWORD #{sql_quote(password)} CREATEDB")
    exec_sql("CREATE DATABASE #{name} OWNER #{username}")

    { "name" => name, "username" => username, "action" => "created" }
  end

  def drop_database(name:, username:)
    # SHAPE ONLY, DELIBERATELY. Shape is injection safety and always applies; the
    # rest is creation POLICY, and applying it here would make a database that
    # already exists undroppable through Conductor the moment the policy changed —
    # while the caller went on to delete the row that tracked it.
    validate_shape!(name)
    validate_shape!(username)

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

  # Pipe the SQL to psql via base64 so no shell quoting of the SQL is needed
  # (survives Net::SSH's `bash -c` wrapping).
  def build_command(sql)
    "echo #{Base64.strict_encode64(sql)} | base64 --decode | docker exec -i " \
      "-e PGPASSWORD=#{Shellwords.escape(cluster.admin_password.to_s)} " \
      "#{Shellwords.escape(cluster.container_name)} " \
      "psql -U #{Shellwords.escape(cluster.admin_username)} -d postgres -v ON_ERROR_STOP=1 -tA"
  end

  # SQL string literal (doubles single quotes).
  def sql_quote(value)
    "'" + value.to_s.gsub("'", "''") + "'"
  end

  MAX_IDENTIFIER_BYTES = 63

  # Two different questions, and an earlier version answered them with one list.
  #
  # UNUSABLE: the name cannot be created, ever — postgres owns it. This is small and
  # knowable, so it is a denylist.
  #
  # RESERVED WORDS: would need quoting to survive interpolation. `users`, `admin` and
  # `root` are NOT in either set — they are perfectly legal identifiers, and rejecting
  # them refused legitimate names in the name of safety.
  UNUSABLE_IDENTIFIERS = %w[postgres template0 template1 public].freeze
  # The PostgreSQL reserved list, including the type/function-name reserved words —
  # an earlier hand-written version omitted `join`, `like`, `is`, `full`, `left`,
  # `right`, `natural`, `cross`, `binary`, `authorization`, `similar`, `tablesample`
  # and the `current_catalog`/`system_user` family, all of which passed validation
  # and then failed as interpolated SQL. Guessing at this list is how it was wrong;
  # it is transcribed, not recalled.
  RESERVED_WORDS = %w[
    all analyse analyze and any array as asc asymmetric authorization binary both
    case cast check collate collation column concurrently constraint create cross
    current_catalog current_date current_role current_schema current_time
    current_timestamp current_user default deferrable desc distinct do else end
    except false fetch for foreign freeze from full grant group having ilike in
    initially inner intersect into is isnull join lateral leading left like limit
    localtime localtimestamp natural not notnull null offset on only or order outer
    overlaps placing primary references returning right select session_user similar
    some symmetric system_user table tablesample then to trailing true union unique
    user using variadic verbose when where window with
  ].freeze

  # Shape is injection safety: it applies to every path, including deletion.
  def validate_shape!(value)
    return if value.to_s.match?(IDENTIFIER)

    raise Error, "Invalid SQL identifier: #{value.inspect}"
  end

  # Creation policy. A caller-supplied name — from the MCP tool or the UI — never
  # passes through App's derivation, so this is the only check standing between it
  # and interpolated SQL.
  # `role:` matters. The admin check is about the ROLE namespace — CREATE ROLE
  # conductor collides with the role that already exists — but a DATABASE called
  # `conductor` is legal and collides with nothing. Applying the check to both
  # refused a legal name for a conflict that only exists on one side.
  def validate_identifier!(value, role: false)
    validate_shape!(value)
    lowered = value.to_s.downcase

    if value.to_s.bytesize > MAX_IDENTIFIER_BYTES
      raise Error, "SQL identifier exceeds postgres's #{MAX_IDENTIFIER_BYTES}-byte limit " \
                   "and would be silently truncated: #{value.inspect}"
    end

    raise Error, "#{value.inspect} is owned by postgres and cannot be created" if UNUSABLE_IDENTIFIERS.include?(lowered)
    raise Error, "#{value.inspect} is a reserved SQL word and would need quoting" if RESERVED_WORDS.include?(lowered)

    return unless role && lowered == cluster.admin_username.to_s.downcase

    raise Error, "#{value.inspect} is already the cluster's admin role"
  end
end
