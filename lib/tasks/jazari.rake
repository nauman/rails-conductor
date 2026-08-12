namespace :jazari do
  desc "Audit preserved legacy runbooks against Jazari"
  task audit_legacy: :environment do
    result = LegacyRunbookAudit.call
    puts "apps=#{result.apps} legacy_items=#{result.legacy_items} jazari_items=#{result.jazari_items}"
    result.issues.each { |issue| puts "drift=#{issue.inspect}" }
    abort "legacy runbook drift detected" unless result.clean?
  end
end
