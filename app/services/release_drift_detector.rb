require "shellwords"

# Does Conductor's record of what is deployed match what is actually running?
#
# Conductor learns about a release when IT performs the deploy. Anything
# deployed another way — a repo script, a CI job whose report is rejected, an
# operator on the box — leaves the record frozen at the last thing Conductor
# saw. That record then keeps being presented as current truth.
#
# The cost is not cosmetic. Conductor's newest record for an externally-deployed
# app was a FAILED deploy from five days earlier against a retired box; a
# downstream agent took that SHA as its release baseline and planned a
# migration-verification protocol for migrations that were already applied. A
# stale record is more dangerous than a missing one, because it is trusted.
#
# This does not try to fix the record. It reports the disagreement, which is the
# honest thing an outside observer can say: "the box is running X, Conductor
# believes Y". Reconciling them is an operator's decision.
#
# FAILS CLOSED. If it cannot inspect the box it reports `unknown`, never
# `in_sync` — the whole point is to stop Conductor being confidently wrong.
#
# Read-only, and never on a request path: like ResidueDetector it makes SSH
# round-trips, so ReleaseDriftCheckJob runs it and the fast paths read the
# stored rollup.
class ReleaseDriftDetector
  # A git SHA as it appears in an image tag. Seven hex chars is the shortest
  # abbreviation git produces by default; `latest` and friends must NOT match,
  # or a mutable tag would be reported as a release.
  SHA_TAG = /\A[0-9a-f]{7,40}\z/

  Result = Struct.new(:status, :recorded_sha, :running_sha, :detail, :remedy, keyword_init: true) do
    # Statuses an operator should be told about. `in_sync` and `not_running`
    # are quiet: one is correct, the other is a state the app's own status
    # already reports.
    def actionable? = %w[drift unrecorded mixed_release unknown].include?(status)
  end

  def initialize(app, ssh: nil)
    @app = app
    @ssh = ssh || (app.server && SshConnection.new(app.server))
  end

  def result
    return unknown("#{@app.name} has no server with SSH access") unless @app.server && @ssh

    containers = running_containers
    return unknown("could not inspect #{@app.server.name}: #{@blind}") if containers.nil?
    return not_running if containers.empty?

    tags = containers.map { |c| c[:tag] }.uniq
    mutable = containers.reject { |c| c[:tag].match?(SHA_TAG) }
    return mutable_tag(mutable, containers) if mutable.any?
    return mixed(containers) if tags.size > 1

    compare(tags.first)
  rescue StandardError => e
    unknown("could not inspect #{@app.server&.name}: #{e.message}")
  end

  private

  def compare(running)
    recorded = recorded_sha

    if recorded.blank?
      return Result.new(
        status: "unrecorded", running_sha: running, recorded_sha: nil,
        detail: "#{@app.name} is running #{running.first(12)} but Conductor has no successful " \
                "deployment recording it — this app was deployed by something other than Conductor",
        remedy: "have the deploy path report to Conductor's deploy webhook, or record the release " \
                "manually; until then Conductor cannot offer this app a rollback"
      )
    end

    return in_sync(recorded, running) if same_commit?(recorded, running)

    Result.new(
      status: "drift", running_sha: running, recorded_sha: recorded,
      detail: "#{@app.name} is running #{running.first(12)}, which is not what Conductor recorded " \
              "(#{recorded.first(12)}) — Conductor's release history for this app is stale",
      remedy: "treat the RUNNING sha as the release baseline, not Conductor's record; then fix the " \
              "deploy path so it reports back"
    )
  end

  # Compare by prefix: the same commit is written at different lengths in
  # different places (short sha in a record, full sha in an image tag), and
  # calling that drift would cry wolf on every healthy app.
  def same_commit?(a, b)
    short, long = [ a.to_s, b.to_s ].sort_by(&:length)
    short.present? && long.start_with?(short)
  end

  # Only a SUCCEEDED deployment describes what is on the box. A failed deploy
  # explicitly did not put its commit there — reading it as the recorded release
  # is how a failure gets mistaken for a baseline.
  def recorded_sha
    @app.deployments.where(status: "succeeded").where.not(commit_sha: [ nil, "" ])
        .order(created_at: :desc).first&.commit_sha
  end

  def in_sync(recorded, running)
    Result.new(status: "in_sync", recorded_sha: recorded, running_sha: running,
               detail: "running #{running.first(12)}, as recorded")
  end

  def not_running
    Result.new(status: "not_running", recorded_sha: recorded_sha,
               detail: "no containers for #{@app.name} are running on #{@app.server.name}",
               remedy: "check the app's status — nothing is serving from this box")
  end

  def mixed(containers)
    shown = containers.map { |c| "#{c[:name]}=#{c[:tag].first(12)}" }.join(", ")
    Result.new(
      status: "mixed_release", running_sha: nil, recorded_sha: recorded_sha,
      detail: "#{@app.name} is running more than one release at once: #{shown}",
      remedy: "a roll stopped part-way — redeploy so every container runs the same image, " \
              "and check the ones left behind for the failure that stopped it"
    )
  end

  def mutable_tag(mutable, _containers)
    shown = mutable.map { |c| "#{c[:name]}=#{c[:tag]}" }.join(", ")
    Result.new(
      status: "unknown", running_sha: nil, recorded_sha: recorded_sha,
      detail: "#{@app.name} runs a mutable image tag (#{shown}), so the running commit cannot be " \
              "identified from it",
      remedy: "deploy sha-tagged images — a mutable tag means the box cannot tell you what it runs, " \
              "and this is NOT a clean result"
    )
  end

  def unknown(detail)
    Result.new(status: "unknown", recorded_sha: safe_recorded_sha, detail: detail,
               remedy: "restore access and re-check — this is NOT a clean result")
  end

  def safe_recorded_sha
    recorded_sha
  rescue StandardError
    nil
  end

  # Containers on the box belonging to this app.
  #
  # Deliberately NOT label-only. Containers Conductor did not start carry no
  # service label at all, and those are exactly the ones most likely to have
  # drifted — a label-only lookup would call a live externally-deployed app
  # "not running", which is the failure this class exists to prevent.
  def running_containers
    out = capture(%(docker ps --format '{{.Names}}|{{.Image}}'))
    return nil if out.nil?

    out.lines.filter_map do |line|
      name, image = line.strip.split("|", 2)
      next if name.blank? || image.blank?
      next unless ours?(name)

      { name: name, image: image, tag: image.rpartition(":").last }
    end
  end

  # Name shapes this app's containers take, across every form it has had.
  # Anchored at the start so another tenant's containers on a shared box are
  # never claimed as ours.
  def ours?(name)
    prefixes = [ @app.resource_key, @app.container_name, @app.slug ].compact_blank
    prefixes.any? { |p| name == p || name.start_with?("#{p}-") }
  end

  def capture(command)
    res = @ssh.execute_with_status(command)
    return res[:output].to_s if res[:success]

    @blind = (res[:stderr].presence || res[:output]).to_s.strip[0, 120]
    nil
  end
end
