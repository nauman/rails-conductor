# Where to ask a registry a question.
#
# Docker Hub's API host differs from its registry name, and its token service is a
# separate host again; everything else follows the OCI distribution spec. This is
# one definition on purpose: two copies drift, and a wrong host does not raise —
# it answers nothing, which every caller here is built to treat as a non-event.
# So a drifted copy is invisible, and the lookup it powers is silently useless.
module RegistryEndpoints
  DOCKER_HUB_NAMES = %w[docker.io index.docker.io].freeze
  DOCKER_HUB_API   = "registry-1.docker.io".freeze

  def self.api_host(registry_host)
    DOCKER_HUB_NAMES.include?(registry_host) ? DOCKER_HUB_API : registry_host
  end

  def self.token_url(registry_host, repository_path)
    if api_host(registry_host) == DOCKER_HUB_API
      "https://auth.docker.io/token?service=registry.docker.io&scope=repository:#{repository_path}:pull"
    else
      "https://#{registry_host}/token?service=#{registry_host}&scope=repository:#{repository_path}:pull"
    end
  end
end
