class EnvVariable < ApplicationRecord
  encrypts :value

  belongs_to :app

  validates :key, presence: true,
                  uniqueness: { scope: :app_id },
                  format: { with: /\A[A-Z_][A-Z0-9_]*\z/, message: "must be uppercase with underscores" }

  scope :secrets, -> { where(secret: true) }
  scope :visible, -> { where(secret: false) }

  def masked_value
    return nil if value.blank?
    secret? ? "••••••••" : value
  end

  def to_docker_env
    "-e #{key}=#{Shellwords.escape(value)}"
  end

  # Same shape as to_docker_env but with secret values masked — for anything
  # that gets logged/displayed (deploy logs must never carry decrypted secrets).
  def to_docker_env_redacted
    "-e #{key}=#{secret? ? "[REDACTED]" : Shellwords.escape(value)}"
  end
end
