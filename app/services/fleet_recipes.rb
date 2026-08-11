# The CONTENT behind FleetCanon's recipe pointers. jazari owns the API; this owns
# the rituals, because recipes are data and the gem ships zero content by design —
# baking fleet specifics into shared architecture would make every ritual fix a gem
# release.
#
# Every step below is seeded from something this fleet already paid for, not from
# imagination. Where a step exists because of an incident, the step says so: a
# checklist that explains itself survives an operator who disagrees with it.
#
# Seeding is create-if-missing (Jazari::RecipeRegistry.seed!), so an operator's edit
# is never overwritten and calling this on every deploy is safe. Item ids are stable
# strings on purpose — an id is how MCP addresses a step, so it must survive an edit
# to the text.
class FleetRecipes
  RECIPES = [
    {
      id: "caddy-mode-app",
      topic: "Deploy a kamal app behind host Caddy (proxy off, fixed port)",
      description: <<~MD,
        ## Purpose
        A kamal artifact on a host-Caddy box. kamal-proxy is OFF and the container
        publishes an exclusive host port, which Caddy reverse-proxies.

        ## Hidden truth
        Only ONE container can hold the published port, so kamal's boot-new-alongside-old
        roll cannot work — there is a brief downtime by design. Worse, when the container
        name is already taken kamal RENAMES the incumbent to `<name>_replaced_<hash>`, and
        `kamal app stop` then matches nothing while the renamed container keeps the port.
        A proxy-less app on this fleet failed three consecutive deploys exactly that way.

        Deploying with a constant version (`KAMAL_VERSION=latest`) guarantees the name
        collision and leaves the release unidentifiable from the image tag. Use sha tags.
      MD
      checklist: [
        { id: "proxy-off", text: "Confirm config/deploy*.yml sets an explicit `proxy: false` — omitting the block is not enough, kamal 2.x still boots the proxy" },
        { id: "sha-tag", text: "Confirm the release is sha-tagged, not `latest` — a mutable tag means the box cannot tell you what it runs" },
        { id: "free-port", text: "Confirm nothing else holds the published port, including a `_replaced_` leftover a name-based stop would miss" },
        { id: "deploy", text: "Deploy through Conductor and record the deployment id + commit" },
        { id: "verify-origin", text: "Verify the origin serves 200 on the published port AND through Caddy on the public host" },
        { id: "dead-containers", text: "Remove containers left `Created` or `_replaced_` by earlier failed boots — they hold no traffic and are not rollback targets", required: false }
      ]
    },
    {
      id: "kamal-proxy-app",
      topic: "Deploy a kamal app behind kamal-proxy (zero-downtime roll)",
      description: <<~MD,
        ## Purpose
        A kamal artifact whose edge is kamal-proxy on the same box. The roll is
        health-check → swap → drain, so there is no downtime.

        ## Hidden truth
        The edge targets a CONTAINER, so it must be republished by every deploy path —
        a deploy that skips it leaves the proxy pointing at a container that no longer
        exists, which reads as an intermittent 502 rather than a clean failure. Route
        keys are `<service>-<role>` (e.g. `myapp-web`), NOT derived from the host, so
        publishing under a host-derived key leaves two services claiming one domain.
      MD
      checklist: [
        { id: "route-key", text: "Confirm the existing route key serving this host, and republish under THAT key rather than one derived from the domain" },
        { id: "deploy", text: "Deploy through Conductor and record the deployment id + commit" },
        { id: "route-target", text: "Confirm the proxy target is the container that is actually running — an orphan route 502s until republished" },
        { id: "verify", text: "Verify the public host serves 200 and the running release matches the intended commit" }
      ]
    },
    {
      id: "external-driver-app",
      topic: "Operate an app Conductor does not deploy",
      description: <<~MD,
        ## Purpose
        The roll is performed by something else — a repo script, CI, or a human. The
        artifact contract may still be kamal, but Conductor must not drive the deploy.

        ## Hidden truth
        A kamal config can be BUILD config only. An externally-driven app on this fleet
        points its `servers:` at a reserved `.invalid` host so `kamal deploy` is impossible — which also
        blocks every other kamal verb, so ops fall back to docker. That is a
        configuration choice, NOT evidence that kamal is inapplicable; an agent read the
        DNS failure and wrongly concluded the harness could not be used at all.

        Conductor's deploy hold is the authoritative boundary here, because it sits
        outside the repo — a hook cannot be, since kamal ships `--skip-hooks`.
      MD
      checklist: [
        { id: "hold", text: "Confirm the Conductor deploy hold is set, with a reason naming the real deploy path" },
        { id: "no-conductor-deploy", text: "Do NOT deploy through Conductor; use the app's own documented path" },
        { id: "ops-path", text: "Use the docker ops path for logs/exec — and record WHY kamal is unavailable rather than leaving a DNS error to speak for it" },
        { id: "release-record", text: "Record the release in Conductor (deploy webhook or manual) or it cannot offer a rollback", required: false }
      ]
    },
    {
      id: "plain-docker-app",
      topic: "Deploy a Conductor-driven docker app",
      description: <<~MD,
        ## Purpose
        A docker artifact Conductor rolls directly: build, pull, recreate.

        ## Hidden truth
        There is no kamal release history, so there is no `rollback` to fall back on —
        the previous image is the only escape, and only if it still exists on the box.
        Docker apps still join the shared docker network so linked containers (the
        shared Postgres, the proxy) resolve by name.
      MD
      checklist: [
        { id: "network", text: "Confirm the container joins the shared docker network, or it cannot reach the shared Postgres by name" },
        { id: "deploy", text: "Deploy through Conductor and record the deployment id + commit" },
        { id: "verify", text: "Verify /up and the running image, and confirm the previous image still exists as the only rollback option" }
      ]
    },
    {
      id: "native-app",
      topic: "Operate a native (host process) app",
      description: <<~MD,
        ## Purpose
        A host process under systemd — no container. Conductor's container-based
        reads (release identification, residue detection) do not apply.

        ## Hidden truth
        Residue for a native app is systemd units and release directories, which
        Conductor does not model — so a clean residue result means "not checked", not
        "clean". Verify by hand.
      MD
      checklist: [
        { id: "unit", text: "Confirm the systemd unit is enabled and active for the deploy user, not root" },
        { id: "release-dir", text: "Confirm the release directory and symlink point at the intended revision" },
        { id: "verify", text: "Verify the public host serves 200 and the process is owned by the deploy user" }
      ]
    }
  ].freeze

  # Create-if-missing, so this is safe to call on every deploy and never overwrites
  # an operator's edit. Returns the records so a caller can report what exists.
  def self.seed!
    Jazari::RecipeRegistry.seed!(RECIPES)
  end

  def self.recipe_ids = RECIPES.map { |r| r[:id] }
end
