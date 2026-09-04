class DatabaseCluster < ApplicationRecord
  include OrganizationConsistency
  validate_same_organization :server
  belongs_to :organization
  belongs_to :server
  has_many :databases, dependent: :destroy

  encrypts :admin_password

  validates :name, :container_name, :admin_username, presence: true

  # Provision a new database (role + database + generated password) on this
  # cluster, recording it as a Database. `client:` is injectable for tests.
  # ASSIGNED IDENTITY (ADR 0011, applying ADR 0004 to the database layer).
  #
  # `container_name` is a display column an operator types and can retype, and it
  # was also the DNS host every dependent app resolved. So renaming a cluster
  # silently broke the next deploy of every app on it — and the transfer path, where
  # source and target are different records on different hosts with live data in
  # flight, derived both ends from typed names.
  #
  # `cluster-<id>` is derived from the primary key, so nothing an operator edits can
  # move it. An ALIAS rather than a label because a connection string needs a name
  # Docker DNS can answer; a label is not addressable from inside a container.
  def resource_key = "cluster-#{id}"

  # THE HOST APPS ACTUALLY RESOLVE, and the narrow point of ADR 0011.
  #
  # A DEDICATED cluster's container_name is already assigned — `app-<id>-db`, from
  # App#dedicated_db_container_name — so it is stable by construction and needs no
  # alias. Replacing it would change the host of every existing dedicated database
  # for no gain, which is what the first version of this did.
  #
  # A SHARED cluster's container_name is typed by an operator at register_cluster and
  # editable afterwards. That is the one doing double duty as a DNS name, and the one
  # a rename silently breaks. Only it gets the assigned alias.
  # The alias is only usable once it EXISTS on the container. Until an operator
  # attaches it, the typed name is still the only thing Docker DNS answers — and
  # switching first would break every app on a shared cluster at its next deploy,
  # all at once, which is worse than the rename this prevents.
  # `network:` is the network the CALLER will resolve from — an app's deploy
  # network. An alias observed on some other network is not reachable from here, so
  # the recorded network has to match; without that the timestamp certified the
  # hostname globally and every app got a name Docker could not resolve.
  def connect_host(network: nil)
    return container_name if assigned_container_name?
    return container_name unless network_alias_attached_at?
    return container_name if network.present? && network_alias_network.to_s != network.to_s

    resource_key
  end

  class AliasNotAttached < StandardError; end

  # RECORDING IS NOT ATTACHING. Setting this timestamp is what switches connect_host
  # to the alias, so recording it speculatively re-hosts every app on the cluster onto
  # a name Docker cannot resolve — and the breakage surfaces at each app's NEXT
  # deploy, far from here.
  #
  # So this OBSERVES, and there is no way to tell it otherwise. An earlier version
  # accepted the aliases as an argument, which only moved the assertion up one frame:
  # a caller could still certify a hostname by passing a list it had made up. The
  # container is the only thing that knows, so the container is asked. `client:` is
  # the seam for tests and it must still answer the same question.
  def alias_attached!(network:, client: nil)
    observed = (client || PostgresContainerClient.new(server))
               .network_aliases(container_name: container_name, network: network)

    unless Array(observed).map(&:to_s).include?(resource_key)
      raise AliasNotAttached,
            "#{resource_key} is not among the aliases on #{container_name} on network " \
            "#{network}; attach it to the container before recording it"
    end

    update!(network_alias_attached_at: Time.current, network_alias_network: network.to_s)
  end

  # ASK, DO NOT PATTERN-MATCH. The first version tested the container name against
  # /app-\d+-db/, which missed the legacy `<slug>-db` spelling and would have aliased
  # a dedicated cluster that was already stable. Guessing whether a name is
  # trustworthy from its shape is the same fragility this ADR removes.
  #
  # App#dedicated_db_container_candidates already answers this authoritatively — it
  # lists both spellings precisely so callers can FIND a dedicated container without
  # knowing which era created it.
  # ONE app, and that app claims the name. Asking only the first database's app read
  # a SHARED cluster as dedicated whenever any one of its tenants happened to be the
  # app the operator named it after — and a shared cluster is exactly the case this
  # method exists to catch.
  # A DECLARED KIND WINS. A one-tenant shared cluster is indistinguishable from a
  # dedicated one by inference alone, and inference is what this whole ADR is trying
  # to get out of. `kind` is NULL for clusters registered before it existed, so they
  # keep the inferred answer rather than being reclassified by a migration.
  def assigned_container_name?
    return kind == "dedicated" if kind.present?

    apps = databases.includes(:app).filter_map(&:app).uniq
    return false unless apps.one?

    apps.first.dedicated_db_container_candidates.include?(container_name)
  end

  # What `docker network connect` needs to make the assigned identity resolvable.
  # Attached at creation for a Conductor-created cluster, and deliberately by an
  # operator for one that already exists — reconnecting a live database container's
  # network is a real interruption, not a side effect to trigger from a read.
  def network_alias_args = [ "--alias", resource_key ]

  def provision_database!(name:, username: nil, app: nil, client: nil)
    username ||= name
    password = SecureRandom.hex(24)
    database = databases.create!(
      organization: organization, app: app,
      name: name, username: username, password: password, status: "pending"
    )

    (client || PostgresClusterClient.new(self)).create_database(
      name: name, username: username, password: password
    )
    database.update!(status: "active")
    database
  rescue StandardError
    database&.update(status: "error")
    raise
  end
end
