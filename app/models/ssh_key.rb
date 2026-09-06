class SshKey < ApplicationRecord
  belongs_to :organization, optional: true

  encrypts :private_key
  encrypts :passphrase

  has_many :servers, dependent: :nullify

  # Scoped per-org so the recommended default ("Conductor deploy key") works in
  # every organization, not just the first to claim the name.
  validates :name, presence: true, uniqueness: { scope: :organization_id }
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

  # THE FORM sshd ACTUALLY READS. `public_key` holds PEM
  # ("-----BEGIN PUBLIC KEY-----"), which is the right thing for display and the
  # wrong thing for authorized_keys: sshd expects one line of
  # `<type> <base64-blob> [comment]` and silently ignores anything else. Appending
  # the PEM would have produced a file that looks installed, authorizes nothing, and
  # reports no error anywhere — sending whoever debugs it back to editing the file
  # by hand, which is the whole thing this is meant to end.
  def authorized_keys_line(comment: "conductor")
    return nil if private_key.blank?

    key = Net::SSH::KeyFactory.load_data_private_key(private_key, passphrase)
    pub = key.respond_to?(:public_key) ? key.public_key : key
    "#{pub.ssh_type} #{[ pub.to_blob ].pack('m0')} #{comment}"
  rescue StandardError
    nil
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
