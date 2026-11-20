namespace :conductor do
  # The only way to create the first admin of an open (SIGNUP_MODE=open) instance
  # besides BOOTSTRAP_ADMIN_EMAIL. Refuses when any admin already exists, so it
  # cannot be used to add a second admin behind the audited toggle_admin path.
  #
  #   bin/rails conductor:bootstrap_admin EMAIL=you@example.com
  desc "Create the first platform admin (refuses if one exists)"
  task bootstrap_admin: :environment do
    email = ENV["EMAIL"].to_s.strip
    abort "EMAIL=you@example.com is required" if email.empty?

    begin
      user = User.bootstrap_admin!(email, operator: true)
    rescue User::BootstrapRefused => e
      raise "Refused: #{e.message}"
    end
    puts "Created platform admin #{user.email}"
  end
end

namespace :conductor do
  # Monthly refresh of the vendored disposable-domain list (plan 02 § 5.2).
  # Review the diff before committing: the list decides who may sign up.
  desc "Refresh config/signup/disposable_email_domains.txt from the upstream list"
  task refresh_disposable_domains: :environment do
    require "net/http"
    body = Net::HTTP.get(URI(DisposableEmail::SOURCE_URL))
    lines = body.lines.map(&:strip).grep(/\A[a-z0-9.-]+\z/)
    abort "Upstream list looks wrong (#{lines.size} domains); not writing" if lines.size < 1000

    header = File.readlines(DisposableEmail::LIST_PATH).take_while { |l| l.start_with?("#") }
    header = header.map { |l| l.sub(/vendored \d{4}-\d{2}-\d{2}/, "vendored #{Date.current}") }
    File.write(DisposableEmail::LIST_PATH, header.join + lines.join("\n") + "\n")
    puts "Wrote #{lines.size} domains"
  end
end
