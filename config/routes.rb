Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

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

  # Organizations — switch the active org (members only)
  resources :organizations, only: [:index] do
    member do
      post :switch
    end
  end

  # First-run onboarding (name your organization)
  resource :onboarding, only: [:show, :update], controller: "onboarding"

  # Organization members + invitations
  resources :members, only: [:index, :destroy]
  resources :invitations, only: [:create]
  get "/invitations/:token/accept", to: "invitations#accept", as: :accept_invitation

  # Database clusters (Hatchbox-style) — per-app databases on a server's Postgres
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

  resources :ssh_keys

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
    end
    resources :cron_jobs, only: [:create, :update, :destroy] do
      collection { post :schedule_script }
    end
  end
  resources :credentials, except: [:show]
  resources :apps do
    member do
      post :deploy
      post :stop
      post :restart
      get :logs
      post :sync_status
      post :provision_database
      post :generate_deploy_key
    end
    collection do
      post :sync_all
    end
    resources :env_variables, only: [:create, :update, :destroy]
  end
  resources :deployments, only: [:show]
  resources :backups do
    member do
      post :run
    end
  end

  resources :scripts
  resources :script_runs, only: [:show]

  # Chat (conversations + nested messages)
  resources :conversations, only: [:index, :show, :create, :destroy] do
    resources :messages, only: [:create]
  end

  # MCP server endpoint (JSON-RPC over HTTP, for AI agents)
  namespace :mcp do
    post :call, to: 'server#call'
    get  :list, to: 'server#list'
  end

  mount ActionCable.server => '/cable'

  # Public docs/guides at /docs (rendered from docs/guides/*.md).
  get "/docs", to: "guides#index"
  get "/docs/:slug", to: "guides#show", as: :guide, constraints: { slug: /[a-z0-9][a-z0-9-]*/ }

  # Public landing page at "/"; the authenticated app dashboard at /dashboard.
  get "dashboard", to: "dashboard#index", as: :dashboard
  root "landing#index"
end
