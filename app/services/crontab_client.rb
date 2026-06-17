require "shellwords"
require "base64"

# Reads and writes a Conductor-managed block inside a server's crontab over SSH,
# mirroring CaddyClient's managed-resource pattern. Each job lives between
# `# >>> conductor:<id>` and `# <<< conductor:<id>` markers, so we only ever
# touch our own entries — hand-written crontab lines are preserved verbatim.
class CrontabClient
  class Error < StandardError; end

  BEGIN_MARKER = "# >>> conductor:".freeze
  END_MARKER   = "# <<< conductor:".freeze

  attr_reader :server

  def initialize(server, ssh_connection: nil)
    @server = server
    @ssh = ssh_connection || SshConnection.new(server)
  end

  # Returns the managed jobs currently installed, as
  # [{ id:, name:, cron_expression:, command:, enabled: }, ...].
  def list_managed
    blocks(read_crontab).map { |id, lines| summarize(id, lines) }
  end

  # Inserts or replaces the managed block for `id`. Disabled jobs are written as
  # a commented-out crontab line so the schedule + command stay visible.
  def upsert_job(id:, name:, cron_expression:, command:, enabled: true)
    id = normalize_id(id)
    crontab = strip_block(read_crontab, id)
    write_crontab(append_block(crontab, build_block(id, name, cron_expression, command, enabled)))

    { "id" => id, "name" => name, "cron_expression" => cron_expression,
      "command" => command, "enabled" => enabled, "action" => "upserted" }
  end

  # Removes only the managed block for `id`; leaves every other line intact.
  def remove_job(id:)
    id = normalize_id(id)
    current = read_crontab
    raise Error, "Managed cron job not found: #{id}" unless blocks(current).key?(id)

    write_crontab(strip_block(current, id))
    { "id" => id, "action" => "removed" }
  end

  def read_crontab
    result = @ssh.execute_with_status("crontab -l 2>/dev/null || true")
    return result[:stdout].to_s if result[:success]

    raise Error, (@ssh.error.presence || result[:stderr].presence || "Could not read crontab")
  end

  private

  def write_crontab(content)
    normalized = content.to_s.gsub(/\n+\z/, "")
    normalized += "\n" unless normalized.empty?

    command = "echo #{Base64.strict_encode64(normalized)} | base64 --decode | crontab -"
    result = @ssh.execute_with_status(command)
    return true if result[:success]

    raise Error, (@ssh.error.presence || result[:stderr].presence || "Could not write crontab")
  end

  # Parses the crontab into { id => [body lines] } for managed blocks only.
  def blocks(crontab)
    result = {}
    current_id = nil
    buffer = nil

    crontab.to_s.lines.each do |line|
      stripped = line.chomp
      if (id = begin_id(stripped))
        current_id = id
        buffer = []
      elsif current_id && end_id(stripped) == current_id
        result[current_id] = buffer
        current_id = nil
        buffer = nil
      elsif current_id
        buffer << stripped
      end
    end

    result
  end

  # Removes the managed block for `id`, preserving all other lines.
  def strip_block(crontab, id)
    kept = []
    skipping = false

    crontab.to_s.lines.each do |line|
      stripped = line.chomp
      if begin_id(stripped) == id
        skipping = true
        next
      elsif skipping && end_id(stripped) == id
        skipping = false
        next
      end

      kept << stripped unless skipping
    end

    kept.join("\n")
  end

  def append_block(crontab, block)
    base = crontab.to_s.gsub(/\n+\z/, "")
    [base.presence, block].compact.join("\n")
  end

  def build_block(id, name, cron_expression, command, enabled)
    entry = "#{cron_expression} #{command}".strip
    entry = "# #{entry}" unless enabled

    [
      "#{BEGIN_MARKER}#{id} #{name}".strip,
      entry,
      "#{END_MARKER}#{id}"
    ].join("\n")
  end

  def summarize(id, lines)
    entry = lines.find { |l| l.strip.present? } || ""
    enabled = !entry.strip.start_with?("#")
    payload = entry.strip.sub(/\A#\s*/, "")
    fields = payload.split(/\s+/, 6)

    {
      id: id,
      name: name_from_marker(id),
      cron_expression: fields.first(5).join(" "),
      command: fields[5].to_s,
      enabled: enabled
    }
  end

  def name_from_marker(id)
    @marker_names ||= {}
    @marker_names[id]
  end

  def begin_id(line)
    return unless line.start_with?(BEGIN_MARKER)

    rest = line.delete_prefix(BEGIN_MARKER)
    id, name = rest.split(" ", 2)
    (@marker_names ||= {})[id] = name.to_s.strip if id
    id
  end

  def end_id(line)
    return unless line.start_with?(END_MARKER)

    line.delete_prefix(END_MARKER).strip
  end

  def normalize_id(id)
    id.to_s.strip
  end
end
