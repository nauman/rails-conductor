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
end
