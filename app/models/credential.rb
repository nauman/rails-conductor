class Credential < ApplicationRecord
  PROVIDERS = %w[cloudflare aws hetzner digitalocean stripe sendgrid].freeze

  encrypts :api_key
  encrypts :api_secret

  has_many :backups, dependent: :nullify

  validates :name, presence: true
  validates :provider, presence: true, inclusion: { in: PROVIDERS }

  scope :active, -> { where(active: true) }
  scope :inactive, -> { where(active: false) }
  scope :for_provider, ->(provider) { where(provider: provider) }

  def masked_api_key
    return "•••••••" if api_key.blank?
    "#{api_key[0..3]}•••••#{api_key[-4..]}"
  end

  def masked_api_secret
    return nil if api_secret.blank?
    "#{api_secret[0..3]}•••••#{api_secret[-4..]}"
  end
end
