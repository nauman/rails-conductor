namespace :jazari do
  desc "Audit preserved legacy runbooks against Jazari"
  task audit_legacy: :environment do
    result = LegacyRunbookAudit.call
    puts "apps=#{result.apps} legacy_items=#{result.legacy_items} jazari_items=#{result.jazari_items}"
    # Print what is accounted for, not just what failed. A silent exception is a
    # difference nobody re-examines, which is how a stale allowance outlives its
    # reason. Green here means "nothing unexplained".
    result.explained.each { |e| puts "explained=#{e[:app_id]}/#{e[:field]} — #{e[:reason]}" }
    result.issues.each { |issue| puts "UNEXPLAINED=#{issue.inspect}" }
    abort "unexplained legacy runbook drift detected" unless result.clean?
    puts "audit green: #{result.explained.size} accounted for, 0 unexplained"
  end
end
