namespace :database_naming do
  desc "Report apps whose derived database name changed under the naming rules (ADR 0011)"
  task audit: :environment do
    # Three separate questions, because an earlier version asked only the first and
    # reported "nothing to migrate" while two other classes of problem sat in the data.
    puts "apps: #{App.count}   databases: #{Database.count}"
    at_risk = []

    # 1. Apps whose DERIVED name changed at all — not only the ones that fell back.
    #    A long name that now truncates differently changed too, and stays non-nil.
    App.find_each do |app|
      derived  = app.database_base_name
      recorded = app.databases.where(status: "active").pluck(:name, :username)

      if recorded.any?
        expected = "#{derived}#{App::DATABASE_SUFFIX}"
        recorded.each do |name, username|
          next if name == expected

          puts "  ##{app.id} #{app.slug.inspect}: recorded #{name.inspect} (role #{username.inspect}) " \
               "but the convention now derives #{expected.inspect} — protected by record-wins, " \
               "and it will stay that way"
        end
      elsif app.derived_database_base_name.nil?
        at_risk << app
        puts "  ##{app.id} #{app.slug.inspect} → #{derived}   AT RISK — no active Database row; " \
             "a re-provision would create #{app.database_name}"
      end
    end

    # 2. Database rows that no app links to. Record-wins cannot protect what it
    #    cannot reach from an app, and these are invisible to the check above.
    orphans = Database.where(app_id: nil)
    orphans.find_each do |db|
      puts "  database ##{db.id} #{db.name.inspect} on cluster #{db.database_cluster_id} " \
           "has no app — nothing derives or protects this name"
    end

    # 3. Stored identifiers the CREATION guard would now refuse. These are droppable
    #    (the drop path checks shape only) but could not be re-created as they are.
    unrecreatable = Database.all.select do |db|
      client = PostgresClusterClient.new(db.database_cluster)
      begin
        client.send(:validate_identifier!, db.name)
        client.send(:validate_identifier!, db.username, role: true)
        false
      rescue PostgresClusterClient::Error
        true
      end
    end
    unrecreatable.each do |db|
      puts "  database ##{db.id} #{db.name.inspect}/#{db.username.inspect} exists but the creation " \
           "policy would refuse it — it can still be dropped, not re-provisioned as-is"
    end

    puts
    puts "#{at_risk.size} at risk, #{orphans.count} unlinked, #{unrecreatable.size} un-recreatable."
    puts "At-risk apps hold a database Conductor has no row for. Record it (or confirm the " \
         "app manages its own DATABASE_URL) before relying on the convention."
  end
end
