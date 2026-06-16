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

  # Letter opener web (development only)
  mount LetterOpenerWeb::Engine, at: "/letter_opener" if Rails.env.development?

  resources :ssh_keys
  resources :servers do
    member do
      post :test_connection
      post :refresh_metrics
      post :provision
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

  # Defines the root path route ("/")
  root "dashboard#index"
end
