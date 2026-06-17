class DeployKey < ApplicationRecord
  belongs_to :app

  encrypts :private_key

  validates :public_key, presence: true
  validates :private_key, presence: true

  # Generate (or regenerate) a deploy key for the app. The caller surfaces
  # #public_key for the operator to add to the repo's GitHub deploy keys.
  def self.generate_for(app, generator: DeployKeyGenerator)
    pair = generator.generate(comment: "conductor-#{app.slug}")
    transaction do
      app.deploy_key&.destroy
      create!(app: app, private_key: pair[:private_key], public_key: pair[:public_key], fingerprint: pair[:fingerprint])
    end
  end

  # Convert an https repo URL to its SSH form so the deploy key is used:
  #   https://github.com/org/repo(.git) -> git@github.com:org/repo.git
  def self.ssh_url(url)
    if url.to_s =~ %r{\Ahttps?://([^/]+)/(.+?)(?:\.git)?/?\z}
      "git@#{$1}:#{$2}.git"
    else
      url
    end
  end
end
