# Supports the two-strikes rule on an empty Cloudflare zone response.
#
# A narrowed token returns SUCCESS with zero zones, and writing that erases the
# cache into a state indistinguishable from an account that owns nothing. Refusing
# it outright was the first fix and wedged the opposite case: an account whose
# zones really were deleted could never re-verify.
#
# One observation is suspicious; two in a row is the world.
class AddConsecutiveEmptyZoneReadsToCredentials < ActiveRecord::Migration[8.0]
  def change
    add_column :credentials, :consecutive_empty_zone_reads, :integer, default: 0, null: false
  end
end
