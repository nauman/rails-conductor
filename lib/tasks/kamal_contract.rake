namespace :kamal do
  desc "List kamal apps that predate the self-describing rule (ADR 0003) and still write raw secrets"
  task self_describing_audit: :environment do
    kamal = App.where(deploy_method: "kamal").order(:id)
    stale = kamal.reject(&:self_describing?)

    puts "kamal apps: #{kamal.count}   compliant: #{kamal.count - stale.size}   grandfathered: #{stale.size}"

    if stale.empty?
      puts "Every kamal app generates its own deploy overlay and git-safe secrets. Nothing to migrate."
      next
    end

    puts
    stale.each do |app|
      secrets = app.env_variables.count(&:secret?)
      puts "  ##{app.id} #{app.slug} on #{app.server&.name || 'no server'} — " \
           "#{secrets} sensitive #{'value'.pluralize(secrets)} currently written as RAW VALUES to .kamal/secrets"
    end

    puts
    puts "Each of these writes plaintext credentials into the deploy checkout. Migrating one:"
    puts "  1. Read the ritual: conductor_runbook action=get_ritual recipe_id=migrate-to-self-describing"
    puts "  2. Set self_describing on the app, deploy it, and verify the release."
    puts "Do them one at a time — the generated config replaces what the app's repo declares,"
    puts "and a shape change nobody watches is how this fleet has been bitten before."
  end
end
