require "test_helper"

# Editing a credential used to ERASE its secret.
#
# api_key and api_secret are `encrypts`-ed, and the edit form posts whatever is
# in the field. Any save that submits an empty secret — renaming the credential,
# fixing an endpoint, changing the region — overwrote the stored value with "".
# The save reported success and nothing indicated the credential was now broken.
#
# This is not hypothetical: it is how a working S3 key pair becomes half a key
# pair, and the resulting upload failure was invisible until 2026-08-03 because
# a failed upload was recorded as a successful backup.
class CredentialSecretRetentionTest < ActiveSupport::TestCase
  setup do
    user = User.create!(email: "cs@example.com")
    @org = Organization.create_for(user, name: "Acme")
    @cred = @org.credentials.create!(name: "r2", provider: "aws",
                                     api_key: "AKIAEXAMPLE", api_secret: "SUPERSECRET")
  end

  test "a blank secret on update leaves the stored one alone" do
    @cred.update!(name: "r2 renamed", api_secret: "")

    assert_equal "SUPERSECRET", @cred.reload.api_secret
    assert_equal "r2 renamed", @cred.name, "the rest of the edit must still apply"
  end

  test "a nil secret on update leaves the stored one alone" do
    @cred.update!(name: "renamed again", api_secret: nil)

    assert_equal "SUPERSECRET", @cred.reload.api_secret
  end

  test "the same protection covers api_key" do
    @cred.update!(name: "x", api_key: "")

    assert_equal "AKIAEXAMPLE", @cred.reload.api_key
  end

  test "a real new secret still replaces the old one" do
    @cred.update!(api_secret: "ROTATED")

    assert_equal "ROTATED", @cred.reload.api_secret
  end

  # Creation is unaffected — a credential that genuinely has no secret (a
  # Cloudflare API token, a GitHub token) must still be creatable.
  test "a credential can still be created with no secret at all" do
    c = @org.credentials.create!(name: "cf token", provider: "cloudflare", api_key: "tok")

    assert c.persisted?
    assert c.api_secret.blank?
  end

  # Deliberate clearing must remain possible — just not by accident.
  test "clearing is possible, but only explicitly" do
    @cred.clear_api_secret!

    assert @cred.reload.api_secret.blank?
  end

  # Rotating a secret must re-open verification: a credential verified with the
  # OLD secret is not evidence about the new one.
  test "an actual secret change still invalidates verification" do
    @cred.update_columns(verified_at: Time.current)
    @cred.update!(api_secret: "ROTATED")

    assert_nil @cred.reload.verified_at, "a rotated secret is unverified until re-checked"
  end

  test "a blank submit does NOT invalidate verification, because nothing changed" do
    @cred.update_columns(verified_at: Time.current)
    @cred.update!(name: "just a rename", api_secret: "")

    assert @cred.reload.verified_at.present?, "a no-op must not look like a rotation"
  end
end
