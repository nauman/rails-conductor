# Active Record Encryption Configuration
# In production, these MUST be stored in credentials.yml.enc or ENV vars.
# Fallback values are for development/test convenience only.

if Rails.env.production?
  Rails.application.config.active_record.encryption.primary_key =
    Rails.application.credentials.dig(:active_record_encryption, :primary_key) ||
    ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
  Rails.application.config.active_record.encryption.deterministic_key =
    Rails.application.credentials.dig(:active_record_encryption, :deterministic_key) ||
    ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
  Rails.application.config.active_record.encryption.key_derivation_salt =
    Rails.application.credentials.dig(:active_record_encryption, :key_derivation_salt) ||
    ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
else
  Rails.application.config.active_record.encryption.primary_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", "idXZ8AynWttAlADaMrqwKF6EJvdJVZf2")
  Rails.application.config.active_record.encryption.deterministic_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY", "fr7tv8LiW3MmqUYkxVKyvLwtXsDPVj0j")
  Rails.application.config.active_record.encryption.key_derivation_salt = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", "nKpXfSXMyHYhfFmoNDDQKxhisZTStY9N")
end
