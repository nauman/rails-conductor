require "shellwords"

class AppTransferRunner
  # Production binding for Execute — turns each orchestration call into a real
  # fleet action via the already-tested transfer primitives. Thin by design:
  # every method is a direct call into one service. Constructed explicitly (with
  # the object-store credential + bucket for replication) by whatever triggers a
  # transfer, so a run is always a deliberate, supervised operation.
  class FleetDeps
    include CloudflareZoneResolver

    def initialize(transfer, credential:, bucket:, provider: "cloudflare_r2")
      @t = transfer
      @app = transfer.app
      @source = transfer.source_server || @app.server
      @target = transfer.target_server
      @credential = credential
      @bucket = bucket
      @provider = provider
    end

    # Provision the (empty) <app>-db container on the target; returns its Database.
    def provision_target_db!
      DedicatedDbProvisioner.new(app: @app, server: @target).provision!
    end

    # Copy the source database into the target's via object storage (R2 default).
    def replicate!(source_url:, target_url:)
      DatabaseReplicator.new(
        source_server: @source, source_url: source_url,
        target_server: @target, target_url: target_url,
        credential: @credential, bucket: @bucket, provider: @provider,
        object_key: "transfers/#{@app.slug}/#{@t.id}.sql.gz"
      ).run!
    end

    # Deploy the app to the target box (its own Deployment record).
    def deploy_to_target!
      deployment = @app.deployments.create!(server: @target, status: "pending", kind: "transfer")
      return if KamalDeployer.new(@app, deployment, target_server: @target).deploy!

      raise "deploy of #{@app.slug} to #{@target.name} failed"
    end

    # Publish the domain on the target's edge (Caddy imperative; on kamal-proxy the
    # deploy already registered it, so this is a confirming no-op there).
    def publish_edge!(domain:)
      Edge.for(@target).publish(domain: domain, upstream: "localhost:#{@app.port || 3000}")
    end

    # Repoint DNS to the target box via the connected Cloudflare account.
    def repoint_dns!(domain:, ip:)
      credential, zone = resolve_cloudflare_zone(@app.organization, domain)
      raise "no connected Cloudflare zone owns #{domain}" unless zone

      CloudflareClient.new(credential.api_key).upsert_dns_record(zone["id"], name: domain, content: ip, type: "A", proxied: false)
    end

    # Stop the app on the source after the hold window (kept idempotent/quiet).
    def stop_source!
      SshConnection.new(@source).execute_with_status("docker stop #{Shellwords.escape(@app.slug)} 2>/dev/null || true")
    end
  end
end
