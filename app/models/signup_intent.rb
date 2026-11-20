require "openssl"
require "ipaddr"

# A request to create an account, before the email is proved (plan 02 § 3).
#
# No User exists until the emailed link is clicked: an unclicked intent is a row
# that expires and is purged, never an account. The email is stored encrypted
# (it is needed to create the user on click); lookups and throttles use a keyed
# digest of it instead.
class SignupIntent < ApplicationRecord
  TTL = 24.hours
  # Verified sign-ups per IPv4 /24 (IPv6 /48) per day (§ 5.2, delegated default).
  VERIFIED_PER_PREFIX_PER_DAY = 3

  class Refused < StandardError; end

  encrypts :email

  scope :unconsumed, -> { where(consumed_at: nil) }
  scope :purgeable, ->(now = Time.current) { where(created_at: ...(now - TTL)) }

  validates :email, :email_digest, :token_digest, :expires_at, :terms_accepted_at, presence: true

  def self.normalize(email) = email.to_s.strip.downcase

  def self.digest(value, purpose:)
    OpenSSL::HMAC.hexdigest("SHA256", Rails.application.secret_key_base, "#{purpose}:#{value}")
  end

  def self.email_digest(email) = digest(normalize(email), purpose: "signup-email")

  # Group addresses the way a single abuser's addresses group: an IPv4 /24, an
  # IPv6 /48. Unparseable input groups under itself, which only ever limits more.
  def self.ip_prefix(ip)
    addr = IPAddr.new(ip.to_s)
    addr.ipv4? ? "#{addr.mask(24)}/24" : "#{addr.mask(48)}/48"
  rescue IPAddr::Error, ArgumentError
    ip.to_s
  end

  # Record the intent and return [intent, raw_token]. The raw token exists only
  # in the emailed link; the row keeps its digest.
  def self.start!(email:, ip:, now: Time.current)
    raw = SecureRandom.urlsafe_base64(32)
    intent = create!(
      email: normalize(email), email_digest: email_digest(email),
      token_digest: digest(raw, purpose: "signup-token"),
      ip: ip.to_s, ip_prefix: ip_prefix(ip),
      terms_accepted_at: now, expires_at: now + TTL
    )
    [ intent, raw ]
  end

  def self.find_by_raw_token(raw)
    return nil if raw.blank?

    find_by(token_digest: digest(raw.to_s, purpose: "signup-token"))
  end

  def usable?(now: Time.current)
    consumed_at.nil? && expires_at > now
  end

  # The click. In one transaction: create the verified user (never an admin),
  # the self-signed-up `new` org, and mark the intent spent. Raises Refused with a
  # message safe to show the person who clicked.
  def consume!(now: Time.current)
    transaction do
      lock!
      raise Refused, "This sign-up link has expired or was already used. Start again." unless usable?(now: now)
      if self.class.where(ip_prefix: ip_prefix, consumed_at: (now - 1.day)..).count >= VERIFIED_PER_PREFIX_PER_DAY
        raise Refused, "Too many accounts were created from your network today. Try again tomorrow."
      end

      user = User.find_by(email: email)
      if user.nil?
        user = User.create!(email: email, admin: false, email_verified_at: now)
        org = Organization.create!(name: email.split("@").first.presence || "workspace",
                                   trust_level: "new", signup_source: Organization::OPEN_SIGNUP)
        org.add_member(user, role: :owner)
      end
      update!(consumed_at: now)
      user
    end
  end
end
