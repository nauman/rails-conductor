# When a Conductor release boots, finalize any self-managed deployment the
# previous container couldn't record — it was replaced mid-`kamal deploy`, so its
# job was killed before marking success. Kamal injects the deployed git sha as
# KAMAL_VERSION; SelfDeployReconciler matches it to the in-progress deployment.
#
# Guarded to real kamal releases (KAMAL_VERSION present), so dev/test/console and
# plain rake runs skip it. Never allowed to break boot.
Rails.application.config.after_initialize do
  next if App.current_release_version.blank?

  begin
    SelfDeployReconciler.run
  rescue => e
    Rails.logger.warn("[SelfDeployReconciler] boot reconcile skipped: #{e.message}")
  end
end
