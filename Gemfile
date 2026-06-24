source "https://rubygems.org"

# Bundle edge Rails instead: gem "rails", github: "rails/rails", branch: "main"
gem "rails", "~> 8.1.1"
# The modern asset pipeline for Rails [https://github.com/rails/propshaft]
gem "propshaft"
# Use PostgreSQL as the database for Active Record
gem "pg", "~> 1.5"
# Use the Puma web server [https://github.com/puma/puma]
gem "puma", ">= 5.0"
# Use JavaScript with ESM import maps [https://github.com/rails/importmap-rails]
gem "importmap-rails"
# Hotwire's SPA-like page accelerator [https://turbo.hotwired.dev]
gem "turbo-rails"
# Hotwire's modest JavaScript framework [https://stimulus.hotwired.dev]
gem "stimulus-rails"
# Use Tailwind CSS [https://github.com/rails/tailwindcss-rails]
gem "tailwindcss-rails"

# Use Active Model has_secure_password [https://guides.rubyonrails.org/active_model_basics.html#securepassword]
# gem "bcrypt", "~> 3.1.7"

# Passwordless authentication
gem "passwordless", "~> 1.0"

# Multi-provider AI (Anthropic, OpenAI, Ollama)
gem "ruby_llm", "~> 1.16"

# SSH connectivity
gem "net-ssh", "~> 7.2"
gem "ed25519", "~> 1.3"        # Ed25519 key support
gem "bcrypt_pbkdf", "~> 1.1"   # OpenSSH key format support

# Windows does not include zoneinfo files, so bundle the tzinfo-data gem
gem "tzinfo-data", platforms: %i[ windows jruby ]

# Use the database-backed adapters for Rails.cache, Active Job, and Action Cable
gem "solid_cache"
gem "solid_queue"
gem "solid_cable"

# Reduces boot times through caching; required in config/boot.rb
gem "bootsnap", require: false

# Deploy this application anywhere as a Docker container [https://kamal-deploy.org]
gem "kamal", require: false

# Add HTTP asset caching/compression and X-Sendfile acceleration to Puma [https://github.com/basecamp/thruster/]
gem "thruster", require: false

# Render the in-product docs/guides (pure-Ruby markdown — no native build).
gem "kramdown"
gem "kramdown-parser-gfm"

# Use Active Storage variants [https://guides.rubyonrails.org/active_storage_overview.html#transforming-images]
gem "image_processing", "~> 1.2"

# Rate limiting and request throttling
gem "rack-attack"

# AWS SES for transactional email
gem "aws-sdk-ses", require: false

# S3-compatible storage (AWS S3, Cloudflare R2)
gem "aws-sdk-s3", require: false

# Error tracking
gem "sentry-ruby"
gem "sentry-rails"

group :development, :test do
  # Pin minitest to the 5.x line: minitest 6 changed Runnable#run's arity and
  # breaks Rails 8.1's line_filtering test runner (silently reports "0 runs").
  gem "minitest", "~> 5.27"

  # See https://guides.rubyonrails.org/debugging_rails_applications.html#debugging-with-the-debug-gem
  gem "debug", platforms: %i[ mri windows ], require: "debug/prelude"

  # Audits gems for known security defects (use config/bundler-audit.yml to ignore issues)
  gem "bundler-audit", require: false

  # Static analysis for security vulnerabilities [https://brakemanscanner.org/]
  gem "brakeman", require: false

  # Omakase Ruby styling [https://github.com/rails/rubocop-rails-omakase/]
  gem "rubocop-rails-omakase", require: false
end

group :development do
  # Use console on exceptions pages [https://github.com/rails/web-console]
  gem "web-console"

  # Preview emails in browser
  gem "letter_opener"
  gem "letter_opener_web"
end
