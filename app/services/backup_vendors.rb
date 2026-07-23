# S3-compatible backup destinations. Every vendor speaks the S3 API — they differ
# only by endpoint, region, and path-style addressing. One registry line per vendor;
# DatabaseBackup builds a single uniform `aws s3 cp` from this.
#
# A vendor resolves its config from a Credential (api_key = access key id,
# api_secret = secret, plus account_id / region / endpoint as needed).
module BackupVendors
  Vendor = Struct.new(:key, :label, :endpoint_fn, :default_region, :path_style, :fields, keyword_init: true) do
    def endpoint(cred) = endpoint_fn&.call(cred)
    def region(cred)   = cred.region.presence || default_region
    # Which credential fields this vendor actually needs (drives the dynamic form).
    def needs?(field)  = fields.include?(field)
  end

  REGISTRY = {
    "aws_s3" => Vendor.new(
      key: "aws_s3", label: "Amazon S3", endpoint_fn: nil,
      default_region: "us-east-1", path_style: false, fields: %i[region]
    ),
    "cloudflare_r2" => Vendor.new(
      key: "cloudflare_r2", label: "Cloudflare R2",
      endpoint_fn: ->(c) { "https://#{c.account_id}.r2.cloudflarestorage.com" },
      default_region: "auto", path_style: false, fields: %i[account_id]
    ),
    "wasabi" => Vendor.new(
      key: "wasabi", label: "Wasabi",
      endpoint_fn: ->(c) { "https://s3.#{c.region.presence || 'us-east-1'}.wasabisys.com" },
      default_region: "us-east-1", path_style: false, fields: %i[region]
    ),
    "backblaze_b2" => Vendor.new(
      key: "backblaze_b2", label: "Backblaze B2",
      endpoint_fn: ->(c) { "https://s3.#{c.region.presence || 'us-west-004'}.backblazeb2.com" },
      default_region: "us-west-004", path_style: false, fields: %i[region]
    ),
    "do_spaces" => Vendor.new(
      key: "do_spaces", label: "DigitalOcean Spaces",
      endpoint_fn: ->(c) { "https://#{c.region.presence || 'nyc3'}.digitaloceanspaces.com" },
      default_region: "nyc3", path_style: false, fields: %i[region]
    ),
    "minio" => Vendor.new(
      key: "minio", label: "MinIO / custom S3",
      endpoint_fn: ->(c) { c.endpoint },
      default_region: "us-east-1", path_style: true, fields: %i[endpoint region]
    ),
    "local" => Vendor.new(
      key: "local", label: "Local (on the server)", endpoint_fn: nil,
      default_region: nil, path_style: false, fields: []
    )
  }.freeze

  module_function

  def [](key) = REGISTRY[key.to_s]
  def all = REGISTRY.values
  def s3_compatible = REGISTRY.values.reject { |v| v.key == "local" }
end
