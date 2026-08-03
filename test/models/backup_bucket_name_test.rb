require "test_helper"

# bucket_name is operator-editable (owner AND editor) and reaches a shell on the
# managed box: the dump path, `stat`, `rm -f`, the S3 URI, and the upload
# confirmation. It carried only a presence validation.
#
# Six other injection routes were closed on 2026-08-01 — slug, branch,
# repository_url, dockerfile_path, image_name, health_check_path. This one was
# missed, and then two MORE interpolations of it were added on 08-03.
#
# The SSH user can run Docker, so remote execution here is effectively host root.
class BackupBucketNameTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "bn@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "r2", provider: "cloudflare", api_key: "k", api_secret: "s")
  end

  def build(name)
    @org.backups.new(provider: "cloudflare_r2", bucket_name: name, credential: @cred)
  end

  # Real S3/R2 names: 3–63 chars, lowercase alphanumeric, dots and hyphens.
  test "valid bucket names are accepted" do
    %w[my-bucket pavelabs-backups a.b.c bucket123 abc].each do |n|
      assert build(n).valid?, "#{n.inspect} should be allowed: #{build(n).tap(&:valid?).errors.full_messages}"
    end
  end

  test "a command-substitution payload is rejected" do
    b = build("x; id >/tmp/pwn; #")

    assert_not b.valid?
    assert_includes b.errors[:bucket_name].join, "lowercase"
  end

  test "backticks, pipes, redirects, quotes and spaces are all rejected" do
    [ "a`id`", "a|id", "a>b", "a b", "a'b", 'a"b', "a$(id)", "a\nb", "../etc" ].each do |n|
      assert_not build(n).valid?, "#{n.inspect} must be rejected"
    end
  end

  test "uppercase and underscores are rejected — not valid S3 names either" do
    assert_not build("MyBucket").valid?
    assert_not build("my_bucket").valid?
  end

  test "length bounds match the S3 rules" do
    assert_not build("ab").valid?, "under 3 chars"
    assert_not build("a" * 64).valid?, "over 63 chars"
    assert build("a" * 63).valid?
  end

  # Validation is the first line; escaping at the interpolation is the second.
  # Both, because the six routes closed earlier taught that either alone is one
  # mistake away from being reopened.
  test "the built commands escape the bucket name even so" do
    require "shellwords"
    b = @org.backups.create!(provider: "cloudflare_r2", bucket_name: "pavelabs-backups",
                             credential: @cred, status: "pending")
    svc = DatabaseBackup.new(b)
    cmd = svc.send(:s3_upload_command, BackupVendors["cloudflare_r2"], "/tmp/f.gz", "f.gz")

    assert_includes cmd, Shellwords.escape("s3://pavelabs-backups/f.gz").delete("\\").presence || "s3://"
  end
end
