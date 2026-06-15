# Active Record Encryption Configuration
# In production, these MUST be stored in credentials.yml.enc or ENV vars.
# Fallback values are for development/test convenience only.

if Rails.env.production?
  # During image build (assets:precompile runs with SECRET_KEY_BASE_DUMMY=1) the
  # real keys aren't injected yet. Use throwaway placeholders then; require the
  # real keys at runtime.
  building = ENV["SECRET_KEY_BASE_DUMMY"].present?
  fetch_key = lambda do |credential, env_var|
    Rails.application.credentials.dig(:active_record_encryption, credential) ||
      ENV[env_var] ||
      (building ? "build_placeholder_#{env_var.downcase}" : ENV.fetch(env_var))
  end

  Rails.application.config.active_record.encryption.primary_key =
    fetch_key.call(:primary_key, "ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY")
  Rails.application.config.active_record.encryption.deterministic_key =
    fetch_key.call(:deterministic_key, "ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY")
  Rails.application.config.active_record.encryption.key_derivation_salt =
    fetch_key.call(:key_derivation_salt, "ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT")
else
  Rails.application.config.active_record.encryption.primary_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY", "idXZ8AynWttAlADaMrqwKF6EJvdJVZf2")
  Rails.application.config.active_record.encryption.deterministic_key = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY", "fr7tv8LiW3MmqUYkxVKyvLwtXsDPVj0j")
  Rails.application.config.active_record.encryption.key_derivation_salt = ENV.fetch("ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT", "nKpXfSXMyHYhfFmoNDDQKxhisZTStY9N")
end
