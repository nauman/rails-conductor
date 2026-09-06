Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Public build-info: the running release's git sha (KAMAL_VERSION), for
  # externally verifying deploys against origin/main HEAD.
  get "version" => "version#show", as: :version

  # OAuth 2.1 authorization server for the MCP endpoint (spec 06) — lets any MCP
  # client connect with a browser login instead of a pasted bearer token.
  # authorize/token/revoke come from doorkeeper; the human-facing application
  # management UIs are skipped because clients register dynamically below.
  # Guarded so an image built before doorkeeper was added still boots (OAuth
  # degrades instead of 500-ing every route).
  if respond_to?(:use_doorkeeper)
    use_doorkeeper do
      skip_controllers :applications, :authorized_applications
    end
  end

  # Discovery (RFC 8414 + RFC 9728) and dynamic client registration (RFC 7591).
  get "/.well-known/oauth-authorization-server", to: "oauth/metadata#authorization_server"
  get "/.well-known/oauth-protected-resource", to: "oauth/metadata#protected_resource"
  # Some clients probe the resource-scoped form of the PRM path.
  get "/.well-known/oauth-protected-resource/mcp", to: "oauth/metadata#protected_resource"
  post "/oauth/register", to: "oauth/registrations#create"

  # API for CLI and external integrations
  namespace :api do
    namespace :v1 do
      # Auth
      post "sessions/request_token", to: "sessions#request_token"
      post "sessions/exchange", to: "sessions#exchange"

      # Resources
      resources :servers, only: [:index, :show, :create] do
        member do
          post :provision
          get :metrics
        end
      end
      resources :apps, only: [:index, :show] do
        member do
          post :deploy
          post :stop
          post :restart
          get :logs
        end
      end
      resources :scripts, only: [:index, :show] do
        collection do
          post :run
        end
      end
      resources :backups, only: [:index, :show] do
        member do
          post :run
        end
      end
      resource :status, only: [:show], controller: "status"
      resources :tokens, only: [:index, :destroy]
    end
  end

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Passwordless authentication
  passwordless_for :users, as: :user, at: "/users"

  # User management (admin only)
  resources :users, only: [:index, :create, :destroy] do
    member do
      patch :toggle_admin
    end
  end

  # Organizations — list, create, and switch the active org (members only)
  resources :organizations, only: [:index, :new, :create] do
    member do
      post :switch
    end
  end

  # First-run onboarding (name your organization)
  resource :onboarding, only: [:show, :update], controller: "onboarding"

  # Organization members + invitations
  resources :members, only: [:index, :update, :destroy]
  resources :invitations, only: [:create]
  get "/invitations/:token/accept", to: "invitations#accept", as: :accept_invitation

  # Database clusters (PaaS-style) — per-app databases on a server's Postgres
  resources :database_clusters, only: [:index, :show, :new, :create] do
    resources :databases, only: [:create]
  end
  resources :databases, only: [:destroy]

  # Platform admin (webmaster) — cross-org administration
  namespace :admin do
    root to: "organizations#index"
    resources :organizations, only: [:index, :show]
    resources :users, only: [:index]
    resources :mcp_calls, only: [:index]
  end

  # Letter opener web (development only)
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  resources :ssh_keys do
    collection { post :generate }
  end

  # Per-user, org-scoped MCP/API tokens (self-serve issuance for agents).
  resources :mcp_tokens, only: [:index, :create, :destroy]
  # Revoke an OAuth connection (a client the user connected via browser sign-in);
  # :id is the client's application id. Listed on the Tokens page.
  resources :oauth_connections, only: [:destroy]

  # Settings → Integrations: Conductor-wide integrations (GitHub App). Singular
  # resource (one config per instance); admin-gated in the controller.
  resource :integrations, only: [:show, :update], controller: :integrations do
    post :verify
  end

  resources :servers do
    member do
      post :test_connection
      post :refresh_metrics
      post :provision
      get :logs
      get :health
      get :audit
      get :storage
      get :sudo_check
      post :reboot
      post :reclaim_swap
      post :install_packages
      post :apply_updates
    end
    resources :cron_jobs, only: [:create, :update, :destroy] do
      collection { post :schedule_script }
    end
  end
  resources :credentials, except: [:show] do
    member { post :verify }
  end
  resources :apps do
    member do
      post :deploy
      post :stop
      post :restart
      get :logs
      get :jobs
      post :sync_status
      post :provision_database
      post :generate_deploy_key
      patch :toggle_auto_deploy
      patch :toggle_deploy_hold
      patch :toggle_seed_on_next_deploy
      post :check_site
      post :put_behind_cloudflare
      post :edge
      get :deploy_config
      patch :toggle_self_describing
      patch :update_runbook
    end
    collection do
      post :sync_all
      post :put_all_behind_cloudflare
    end
    resources :env_variables, only: [:create, :update, :destroy]
    resources :deploy_checklist_items, only: [:create, :update, :destroy]
  end
  resources :deployments, only: [:show] do
    member { post :rollback }
  end
  resources :backups do
    member do
      post :run
    end
    collection do
      # One button for the whole fleet (design B1): 0 of 12 apps were protected because
      # enabling one asked four questions. This asks none.
      post :protect_all
      # Create the destination bucket from the same screen that asks for its
      # name. Conductor could configure, migrate and CORS a bucket but not make
      # one — so every setup detoured to the Cloudflare dashboard, and the fleet
      # ran ten schedules pointed at a bucket that did not exist.
      post :create_bucket
    end
  end

  resources :scripts
  resources :script_runs, only: [:show]

  # Database pulls — pg_dump a remote DB down to the Conductor host (SCP) and
  # optionally restore it into a local Postgres database.
  resources :database_pulls, only: [:index, :show, :new, :create]

  # Chat (conversations + nested messages)
  resources :conversations, only: [:index, :show, :create, :destroy] do
    resources :messages, only: [:create]
  end

  # A CI/external deploy reports itself back so it becomes a real Deployment row
  # (Q-07-1). Records a finished deploy; does not trigger one. Same per-app HMAC.
  # MUST precede the :provider/:app_id route below, whose two wildcards would
  # otherwise swallow `webhooks/<id>/deployment` (provider=<id>, app_id=deployment).
  post "webhooks/:app_id/deployment", to: "webhooks#report_deployment", as: :deployment_report_webhook

  # Inbound SCM push webhooks → auto-deploy (public; verified by per-app HMAC).
  post "webhooks/:provider/:app_id", to: "webhooks#receive", as: :webhook

  # MCP server endpoints (for AI agents). Two surfaces over the same tools:
  #   - Standard JSON-RPC transport at /mcp — register natively with
  #     `claude mcp add --transport http conductor https://<host>/mcp`.
  #   - Custom REST surface at /mcp/list|call|skill — simple curl access.
  post "mcp", to: "mcp/rpc#handle"
  get  "mcp", to: "mcp/rpc#stream"
  namespace :mcp do
    post :call,  to: 'server#call'
    get  :list,  to: 'server#list'
    get  :skill, to: 'server#skill'
  end

  mount ActionCable.server => '/cable'

  # Public docs/guides at /docs (rendered from docs/guides/*.md).
  get "/docs", to: "guides#index"
  get "/docs/:slug", to: "guides#show", as: :guide, constraints: { slug: /[a-z0-9][a-z0-9-]*/ }

  # Public landing page at "/"; the authenticated app dashboard at /dashboard.
  # Caddy's on-demand TLS gate. Unauthenticated by necessity: Caddy calls it from
  # the host before a certificate exists, and it is the only process on the box that
  # knows every zone — see app/controllers/caddy_ask_controller.rb.
  get "/caddy/ask", to: "caddy_ask#show", as: :caddy_ask

  # Read-only: the shared ritual library, which MCP could read and a person could not.
  resources :rituals, only: [ :index, :show ], id: /[a-z0-9][a-z0-9-]*/

  get "dashboard", to: "dashboard#index", as: :dashboard
  root "landing#index"
end
