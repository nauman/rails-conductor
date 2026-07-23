require "test_helper"

class BackupVendorsTest < ActiveSupport::TestCase
  test "registry covers the S3-compatible vendors + local" do
    keys = BackupVendors.all.map(&:key)
    assert_equal %w[aws_s3 cloudflare_r2 wasabi backblaze_b2 do_spaces minio local].sort, keys.sort
    assert_equal Backup::PROVIDERS.sort, keys.sort, "registry + Backup::PROVIDERS must agree"
  end

  test "s3_compatible excludes local" do
    refute_includes BackupVendors.s3_compatible.map(&:key), "local"
  end

  test "each vendor declares the fields its form needs" do
    assert_includes BackupVendors["cloudflare_r2"].fields, :account_id
    assert_includes BackupVendors["minio"].fields, :endpoint
    assert_includes BackupVendors["wasabi"].fields, :region
  end
end
