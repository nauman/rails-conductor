# Create and list Cloudflare R2 buckets through a connected account.
#
# Conductor could already configure R2 storage for an app, migrate blobs into
# it, set CORS and attach a public domain — everything EXCEPT create the bucket
# all of that depends on. Every R2 setup therefore began with a manual detour to
# the Cloudflare dashboard, outside Conductor's audit trail.
#
# It is also how the fleet came to run ten backup schedules pointed at
# `shared-backups`, a bucket that never existed: nothing here could create it,
# and nothing checked it was there.
#
# Needs a VERIFIED Cloudflare account whose token carries
# "Workers R2 Storage: Edit".
class R2Bucket
  Result = Struct.new(:ok, :message, :bucket, :buckets, keyword_init: true) do
    def ok? = ok
  end

  # R2 bucket naming, which is also shell-safe: 3-63 chars, lowercase
  # alphanumerics and hyphens, not starting or ending with a hyphen. Refused
  # locally so an invalid name never becomes a round-tripped API error.
  NAME = /\A[a-z0-9][a-z0-9-]{1,61}[a-z0-9]\z/

  def initialize(credentials, client_for: nil)
    @credentials = credentials
    @client_for = client_for || ->(cred) { CloudflareClient.new(cred.api_key) }
  end

  # location_hint fixes the bucket's physical region (wnam/enam/weur/eeur/apac/oc)
  # and CANNOT be changed afterwards, so it is passed through rather than
  # defaulted — a wrong guess is permanent.
  def create!(name:, location_hint: nil)
    name = name.to_s.strip
    unless name.match?(NAME)
      return failure("Invalid bucket name #{name.inspect}. R2 names are 3-63 characters, " \
                     "lowercase letters, numbers and hyphens, not starting or ending with a hyphen.")
    end

    cred = account
    return failure("No verified Cloudflare account is connected. Connect + Verify one first.") unless cred

    client = @client_for.call(cred)

    # Idempotent: re-running setup must not fail because the bucket is already
    # there. Checked first so "already exists" reads as success, not an error.
    existing = client.r2_buckets(cred.account_id)
    if existing.ok? && Array(existing.data).any? { |b| b["name"] == name }
      return Result.new(ok: true, bucket: name,
                        message: "R2 bucket #{name} already exists in #{cred.name}.")
    end

    r = client.create_r2_bucket(cred.account_id, name, location_hint: location_hint)
    return failure("Creating the R2 bucket failed: #{r.error}") unless r.ok?

    Result.new(ok: true, bucket: name, message: "R2 bucket #{name} created in #{cred.name}.")
  end

  def list
    cred = account
    return failure("No verified Cloudflare account is connected. Connect + Verify one first.") unless cred

    r = @client_for.call(cred).r2_buckets(cred.account_id)
    return failure("Listing R2 buckets failed: #{r.error}") unless r.ok?

    names = Array(r.data).map { |b| b["name"] }.compact
    Result.new(ok: true, buckets: names, message: "#{names.size} R2 bucket(s) in #{cred.name}.")
  end

  private

  # A verified account with an account_id — both are required: the R2 API is
  # account-scoped, and an unverified token has not been shown to work.
  def account
    @credentials.detect { |c| c.verified_at.present? && c.account_id.present? }
  end

  def failure(message) = Result.new(ok: false, message: message)
end
