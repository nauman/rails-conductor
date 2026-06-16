class SshKey < ApplicationRecord
  belongs_to :organization, optional: true

  encrypts :private_key
  encrypts :passphrase

  has_many :servers, dependent: :nullify

  validates :name, presence: true, uniqueness: true
  validates :private_key, presence: true

  before_save :extract_key_metadata

  def masked_private_key
    return "No key" if private_key.blank?
    lines = private_key.lines
    return private_key if lines.length <= 4
    "#{lines.first}...[#{lines.length - 2} lines]...\n#{lines.last}"
  end

  def usable?
    private_key.present? && fingerprint.present?
  end

  private

  def extract_key_metadata
    return if private_key.blank?

    begin
      key = Net::SSH::KeyFactory.load_data_private_key(private_key, passphrase)
      self.public_key = key.public_key.to_s rescue nil
      self.fingerprint = calculate_fingerprint(key)
      self.key_type = key.class.name.split("::").last.downcase
    rescue => e
      errors.add(:private_key, "is invalid: #{e.message}")
      throw(:abort)
    end
  end

  def calculate_fingerprint(key)
    require "digest"
    blob = key.public_key.to_blob rescue key.to_blob
    "SHA256:#{Base64.strict_encode64(Digest::SHA256.digest(blob)).chomp('=')}"
  rescue
    nil
  end
end
