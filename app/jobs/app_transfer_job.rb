# Runs an AppTransfer end-to-end off the request/MCP path (a transfer deploys to
# B, copies the DB via R2, publishes the edge, repoints DNS, and drains A — far
# too long to run inline). Loads the record, binds the real FleetDeps with the
# operator's object-store credential, and drives AppTransferRunner. Progress +
# final status land on the AppTransfer row (crash-visible), so the caller polls
# rather than waits.
class AppTransferJob < ApplicationJob
  queue_as :default

  def perform(transfer_id, credential_id:, bucket:, provider: "cloudflare_r2")
    transfer = AppTransfer.find(transfer_id)
    credential = transfer.organization.credentials.find(credential_id)

    deps = AppTransferRunner::FleetDeps.new(transfer, credential: credential, bucket: bucket, provider: provider)
    AppTransferRunner.new(transfer, collaborators: AppTransferRunner::Execute.new(transfer, deps: deps)).run
  end
end
