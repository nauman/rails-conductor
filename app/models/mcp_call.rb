class McpCall < ApplicationRecord
  STATUSES = %w[success failed].freeze

  # Argument/result keys whose values are secrets and must never be persisted in
  # the audit log (it's queryable by webmasters and stored unencrypted). Matches
  # e.g. password, admin_password, passphrase, secret, token, api_key,
  # private_key, database_url, and the env-var `value` field.
  SENSITIVE_KEY = /pass(word|phrase)|secret|token|api_key|private_key|database_url|\Avalue\z/i
  REDACTED = "[REDACTED]".freeze

  belongs_to :user, optional: true
  belongs_to :organization, optional: true

  validates :tool_name, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :recent, -> { order(created_at: :desc) }

  def success?
    status == "success"
  end

  # Records a single MCP tool invocation. `result` is a Result-like object
  # responding to #success? and #value/#error; timing is measured by the caller.
  # `organization` is optional: the org a call touched, for the audit log
  # (nil for admin-global calls that don't act on a single org's resource).
  # Secrets in arguments/result are redacted before they are persisted.
  def self.record(tool_name:, arguments:, result:, duration_ms:, user: nil, organization: nil)
    create!(
      user: user,
      organization: organization,
      tool_name: tool_name.to_s,
      arguments: redact(arguments || {}),
      status: result.success? ? "success" : "failed",
      result: (serialized_result(result.value) if result.success? && !result.value.nil?),
      error: (result.error unless result.success?),
      duration_ms: duration_ms
    )
  rescue StandardError => e
    Rails.logger.warn("McpCall.record failed: #{e.message}")
    nil
  end

  # Strip the internal `_organization` marker (an Organization record some tools
  # embed for audit logging) and redact secrets before storing the result JSON.
  def self.serialized_result(value)
    value = value.except(:_organization) if value.is_a?(Hash)
    redact(value).to_json
  end

  # Recursively replaces values under sensitive keys with [REDACTED]. Returns a
  # copy; never mutates the caller's hash (the real values still reach the client
  # via the controller's separate render path).
  def self.redact(obj)
    case obj
    when Hash
      obj.each_with_object({}) do |(k, v), acc|
        acc[k] = SENSITIVE_KEY.match?(k.to_s) ? REDACTED : redact(v)
      end
    when Array
      obj.map { |v| redact(v) }
    else
      obj
    end
  end
end
