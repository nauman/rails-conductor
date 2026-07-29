# Read an AppTransfer's state — phase, status, and (on failure) the error and log.
# The transfer runs as a background job, so without this read a move is
# fire-and-forget: you can start it but can't see why it stalled. Pass transfer_id
# for one run's detail, app_id/app_name for that app's latest, or nothing to list
# the actor's recent transfers. Read-only; org-scoped like every other read.
class TransferStatusTool
  include ActorScoped

  def initialize(user:)
    @user = user
  end

  def call(input)
    if input["transfer_id"].present? || find_app(input)
      transfer = find_transfer(input)
      return Result.fail("Transfer not found. Provide transfer_id, app_id/app_name, or omit for the recent list.") unless transfer

      Result.ok(detail(transfer).merge(_organization: transfer.organization))
    else
      recent = visible_transfers.recent.limit((input["limit"] || 10).to_i.clamp(1, 25))
      Result.ok(transfers: recent.map { |t| summary(t) })
    end
  end

  private

  def visible_transfers
    actor_admin? ? AppTransfer.all : AppTransfer.where(organization_id: actor_org_ids)
  end

  def find_transfer(input)
    if input["transfer_id"].present?
      visible_transfers.find_by(id: input["transfer_id"])
    elsif (app = find_app(input))
      visible_transfers.where(app: app).recent.first
    end
  end

  def summary(t)
    {
      transfer_id: t.id, app: t.app&.name, mode: t.mode,
      status: t.status, phase: t.phase,
      from: t.source_server&.name, to: t.target_server&.name,
      error: t.error, created_at: t.created_at
    }
  end

  # Detail adds the planned phase set (so "phase: database" reads against the whole
  # pipeline) and a log tail — the actionable why behind a failure.
  def detail(t)
    summary(t).merge(
      planned_phases: t.planned_phases,
      started_at: t.started_at, finished_at: t.finished_at,
      log: t.log.to_s.lines.last(40).join
    )
  end
end
