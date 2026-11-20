# Refuses throwaway inboxes at sign-up (plan 02 § 5.2). The list is vendored at
# config/signup/disposable_email_domains.txt; a subdomain of a listed domain is
# refused too (anything.mailinator.com).
module DisposableEmail
  LIST_PATH = Rails.root.join("config", "signup", "disposable_email_domains.txt")
  SOURCE_URL = "https://raw.githubusercontent.com/disposable-email-domains/disposable-email-domains/main/disposable_email_blocklist.conf".freeze

  module_function

  def domains
    @domains ||= File.readlines(LIST_PATH, chomp: true)
                     .map { |l| l.strip.downcase }
                     .reject { |l| l.empty? || l.start_with?("#") }
                     .to_set
  end

  def disposable?(email)
    domain = email.to_s.split("@", 2).last.to_s.strip.downcase
    return false if domain.empty?

    labels = domain.split(".")
    (0...(labels.length - 1)).any? { |i| domains.include?(labels[i..].join(".")) }
  end
end
