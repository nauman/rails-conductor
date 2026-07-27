# Generates the Active Storage config to point an app at Cloudflare R2, in the
# self-describing style (ADR 0001): the real storage.yml service block + the
# production.rb line + the env keys the operator sets (via conductor_app_config
# set_env). Pure — no secret handling, no network. Creds are read from ENV so
# they never live in the repo.
class R2StorageConfig
  ENV_KEYS = %w[R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET].freeze

  def initialize(bucket:, account_id: nil)
    @bucket = bucket.to_s
    @account_id = account_id.to_s
  end

  def storage_yml
    <<~YAML
      cloudflare_r2:
        service: S3
        access_key_id: <%= ENV["R2_ACCESS_KEY_ID"] %>
        secret_access_key: <%= ENV["R2_SECRET_ACCESS_KEY"] %>
        region: auto
        bucket: <%= ENV.fetch("R2_BUCKET", "#{@bucket}") %>
        endpoint: https://<%= ENV["R2_ACCOUNT_ID"] %>.r2.cloudflarestorage.com
        force_path_style: true
    YAML
  end

  def production_rb = "config.active_storage.service = :cloudflare_r2"

  def to_h
    {
      storage_yml_append: storage_yml,
      production_rb_line: production_rb,
      required_env: ENV_KEYS,
      bucket: @bucket,
      account_id_set: @account_id.present?,
      instructions: "Append the storage_yml block to config/storage.yml, set the production.rb line, " \
                    "then set the required_env keys via conductor_app_config action=set_env. " \
                    "Existing files then migrate with conductor_storage action=migrate."
    }
  end
end
