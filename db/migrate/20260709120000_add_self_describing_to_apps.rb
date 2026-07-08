class AddSelfDescribingToApps < ActiveRecord::Migration[8.1]
  # Opt-in per app (ADR 0001). When true, a Kamal deploy writes the generated
  # self-describing artifact (config/deploy.production.yml + .kamal/secrets.production)
  # into the checkout and deploys with `-d production`. Default false → existing
  # apps deploy exactly as before.
  def change
    add_column :apps, :self_describing, :boolean, default: false, null: false
  end
end
