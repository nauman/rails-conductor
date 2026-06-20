# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_06_20_073426) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "api_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "last_used_at"
    t.string "name", null: false
    t.bigint "organization_id"
    t.string "scope", default: "deploy", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id"], name: "index_api_tokens_on_organization_id"
    t.index ["token_digest"], name: "index_api_tokens_on_token_digest", unique: true
    t.index ["user_id"], name: "index_api_tokens_on_user_id"
  end

  create_table "apps", force: :cascade do |t|
    t.boolean "auto_deploy", default: false, null: false
    t.string "branch", default: "main"
    t.string "container_id"
    t.datetime "container_started_at"
    t.string "container_status", default: "unknown"
    t.datetime "created_at", null: false
    t.string "deploy_method", default: "docker", null: false
    t.datetime "deployed_at"
    t.string "dockerfile_path", default: "Dockerfile"
    t.string "domain"
    t.string "health_check_path", default: "/up"
    t.string "image_name"
    t.datetime "last_status_check_at"
    t.string "name", null: false
    t.text "notes"
    t.bigint "organization_id"
    t.integer "port"
    t.string "repository_url"
    t.integer "server_id"
    t.string "slug", null: false
    t.boolean "ssl_enabled", default: true
    t.string "status", default: "stopped"
    t.string "status_check_error"
    t.datetime "updated_at", null: false
    t.string "webhook_secret"
    t.index ["container_status"], name: "index_apps_on_container_status"
    t.index ["organization_id"], name: "index_apps_on_organization_id"
    t.index ["server_id"], name: "index_apps_on_server_id"
    t.index ["slug"], name: "index_apps_on_slug", unique: true
    t.index ["status"], name: "index_apps_on_status"
  end

  create_table "backups", force: :cascade do |t|
    t.integer "app_id"
    t.string "bucket_name", null: false
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.integer "credential_id"
    t.boolean "enabled", default: false
    t.datetime "last_run_at"
    t.datetime "next_run_at"
    t.bigint "organization_id"
    t.string "provider", null: false
    t.integer "retention_days", default: 7
    t.string "schedule", default: "daily"
    t.integer "server_id"
    t.bigint "size_bytes", default: 0
    t.string "status", default: "pending"
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_backups_on_app_id"
    t.index ["credential_id"], name: "index_backups_on_credential_id"
    t.index ["enabled", "next_run_at"], name: "index_backups_on_enabled_and_next_run_at"
    t.index ["organization_id"], name: "index_backups_on_organization_id"
    t.index ["provider"], name: "index_backups_on_provider"
    t.index ["server_id"], name: "index_backups_on_server_id"
    t.index ["status"], name: "index_backups_on_status"
  end

  create_table "conversations", force: :cascade do |t|
    t.jsonb "context", default: {}, null: false
    t.datetime "created_at", null: false
    t.string "status", default: "active", null: false
    t.string "title"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["created_at"], name: "index_conversations_on_created_at"
    t.index ["status"], name: "index_conversations_on_status"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "credentials", force: :cascade do |t|
    t.boolean "active", default: true
    t.text "api_key"
    t.text "api_secret"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "organization_id"
    t.string "provider", null: false
    t.datetime "updated_at", null: false
    t.index ["active"], name: "index_credentials_on_active"
    t.index ["organization_id"], name: "index_credentials_on_organization_id"
    t.index ["provider"], name: "index_credentials_on_provider"
  end

  create_table "cron_jobs", force: :cascade do |t|
    t.text "command", null: false
    t.datetime "created_at", null: false
    t.string "cron_expression", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.string "schedule", null: false
    t.bigint "server_id", null: false
    t.string "status", default: "enabled", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_cron_jobs_on_organization_id"
    t.index ["server_id"], name: "index_cron_jobs_on_server_id"
  end

  create_table "database_clusters", force: :cascade do |t|
    t.text "admin_password"
    t.string "admin_username", null: false
    t.string "container_name", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.integer "port", default: 5432
    t.bigint "server_id", null: false
    t.datetime "updated_at", null: false
    t.index ["organization_id"], name: "index_database_clusters_on_organization_id"
    t.index ["server_id"], name: "index_database_clusters_on_server_id"
  end

  create_table "database_pulls", force: :cascade do |t|
    t.bigint "app_id"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "local_dump_path"
    t.text "log"
    t.bigint "organization_id"
    t.string "restore_target"
    t.bigint "server_id", null: false
    t.bigint "size_bytes", default: 0, null: false
    t.string "source_database"
    t.string "source_database_url_var", default: "DATABASE_URL", null: false
    t.string "source_env_file"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["app_id"], name: "index_database_pulls_on_app_id"
    t.index ["created_at"], name: "index_database_pulls_on_created_at"
    t.index ["organization_id"], name: "index_database_pulls_on_organization_id"
    t.index ["server_id"], name: "index_database_pulls_on_server_id"
    t.index ["status"], name: "index_database_pulls_on_status"
    t.index ["user_id"], name: "index_database_pulls_on_user_id"
  end

  create_table "databases", force: :cascade do |t|
    t.bigint "app_id"
    t.datetime "created_at", null: false
    t.bigint "database_cluster_id", null: false
    t.string "name", null: false
    t.bigint "organization_id", null: false
    t.text "password"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.string "username", null: false
    t.index ["app_id"], name: "index_databases_on_app_id"
    t.index ["database_cluster_id"], name: "index_databases_on_database_cluster_id"
    t.index ["organization_id"], name: "index_databases_on_organization_id"
  end

  create_table "deploy_keys", force: :cascade do |t|
    t.bigint "app_id", null: false
    t.datetime "created_at", null: false
    t.string "fingerprint"
    t.text "private_key", null: false
    t.text "public_key", null: false
    t.datetime "updated_at", null: false
    t.index ["app_id"], name: "index_deploy_keys_on_app_id", unique: true
  end

  create_table "deployments", force: :cascade do |t|
    t.bigint "app_id"
    t.string "commit_sha"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "log"
    t.bigint "script_id"
    t.bigint "server_id"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["app_id"], name: "index_deployments_on_app_id"
    t.index ["script_id"], name: "index_deployments_on_script_id"
    t.index ["server_id"], name: "index_deployments_on_server_id"
    t.index ["status"], name: "index_deployments_on_status"
    t.index ["user_id"], name: "index_deployments_on_user_id"
  end

  create_table "env_variables", force: :cascade do |t|
    t.integer "app_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.boolean "secret", default: false
    t.datetime "updated_at", null: false
    t.text "value"
    t.index ["app_id", "key"], name: "index_env_variables_on_app_id_and_key", unique: true
    t.index ["app_id"], name: "index_env_variables_on_app_id"
  end

  create_table "invitations", force: :cascade do |t|
    t.datetime "accepted_at"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.bigint "invited_by_id", null: false
    t.bigint "organization_id", null: false
    t.integer "role", default: 0, null: false
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.index ["invited_by_id"], name: "index_invitations_on_invited_by_id"
    t.index ["organization_id"], name: "index_invitations_on_organization_id"
    t.index ["token"], name: "index_invitations_on_token", unique: true
  end

  create_table "mcp_calls", force: :cascade do |t|
    t.jsonb "arguments", default: {}, null: false
    t.datetime "created_at", null: false
    t.integer "duration_ms"
    t.text "error"
    t.bigint "organization_id"
    t.text "result"
    t.string "status", default: "success", null: false
    t.string "tool_name", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["created_at"], name: "index_mcp_calls_on_created_at"
    t.index ["organization_id"], name: "index_mcp_calls_on_organization_id"
    t.index ["user_id"], name: "index_mcp_calls_on_user_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "organization_id", null: false
    t.integer "role", default: 0, null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["organization_id"], name: "index_memberships_on_organization_id"
    t.index ["user_id", "organization_id"], name: "index_memberships_on_user_id_and_organization_id", unique: true
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.text "content"
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "role", null: false
    t.integer "sequence", default: 0, null: false
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "sequence"], name: "index_messages_on_conversation_id_and_sequence"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
  end

  create_table "organizations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "onboarded_at"
    t.datetime "updated_at", null: false
  end

  create_table "passwordless_sessions", force: :cascade do |t|
    t.integer "authenticatable_id"
    t.string "authenticatable_type"
    t.datetime "claimed_at", precision: nil
    t.datetime "created_at", null: false
    t.datetime "expires_at", precision: nil, null: false
    t.string "identifier", null: false
    t.datetime "timeout_at", precision: nil, null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["authenticatable_type", "authenticatable_id"], name: "authenticatable"
    t.index ["identifier"], name: "index_passwordless_sessions_on_identifier", unique: true
  end

  create_table "script_runs", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.text "log"
    t.bigint "script_id", null: false
    t.bigint "server_id", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id"
    t.index ["script_id"], name: "index_script_runs_on_script_id"
    t.index ["server_id"], name: "index_script_runs_on_server_id"
    t.index ["status"], name: "index_script_runs_on_status"
  end

  create_table "scripts", force: :cascade do |t|
    t.text "body", null: false
    t.boolean "built_in", default: false, null: false
    t.datetime "created_at", null: false
    t.text "description"
    t.string "name", null: false
    t.string "script_type", default: "provision", null: false
    t.datetime "updated_at", null: false
    t.index ["name"], name: "index_scripts_on_name", unique: true
    t.index ["script_type"], name: "index_scripts_on_script_type"
  end

  create_table "servers", force: :cascade do |t|
    t.string "agent_token"
    t.string "agent_url"
    t.integer "caddy_port"
    t.integer "cpu_percent", default: 0
    t.datetime "created_at", null: false
    t.integer "disk_percent", default: 0
    t.string "hostname"
    t.string "ip_address"
    t.datetime "last_seen_at"
    t.integer "memory_total_mb", default: 0
    t.integer "memory_used_mb", default: 0
    t.datetime "metrics_updated_at"
    t.string "name", null: false
    t.bigint "organization_id"
    t.string "provider"
    t.string "region"
    t.bigint "ssh_key_id"
    t.integer "ssh_port", default: 22
    t.string "ssh_user", default: "deploy"
    t.string "status", default: "inactive"
    t.datetime "updated_at", null: false
    t.integer "uptime_seconds", default: 0, null: false
    t.bigint "user_id"
    t.index ["organization_id"], name: "index_servers_on_organization_id"
    t.index ["ssh_key_id"], name: "index_servers_on_ssh_key_id"
    t.index ["status"], name: "index_servers_on_status"
  end

  create_table "ssh_keys", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "fingerprint"
    t.string "key_type"
    t.string "name", null: false
    t.bigint "organization_id"
    t.text "passphrase"
    t.text "private_key", null: false
    t.text "public_key"
    t.datetime "updated_at", null: false
    t.index ["fingerprint"], name: "index_ssh_keys_on_fingerprint"
    t.index ["name"], name: "index_ssh_keys_on_name", unique: true
    t.index ["organization_id"], name: "index_ssh_keys_on_organization_id"
  end

  create_table "tool_executions", force: :cascade do |t|
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.bigint "message_id", null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.jsonb "tool_input", default: {}, null: false
    t.string "tool_name", null: false
    t.jsonb "tool_output"
    t.datetime "updated_at", null: false
    t.index ["message_id"], name: "index_tool_executions_on_message_id"
    t.index ["status"], name: "index_tool_executions_on_status"
    t.index ["tool_name"], name: "index_tool_executions_on_tool_name"
  end

  create_table "users", force: :cascade do |t|
    t.boolean "admin", default: false, null: false
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.string "name"
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
  end

  add_foreign_key "api_tokens", "organizations"
  add_foreign_key "api_tokens", "users"
  add_foreign_key "apps", "organizations"
  add_foreign_key "apps", "servers"
  add_foreign_key "backups", "apps"
  add_foreign_key "backups", "credentials"
  add_foreign_key "backups", "organizations"
  add_foreign_key "backups", "servers"
  add_foreign_key "conversations", "users"
  add_foreign_key "credentials", "organizations"
  add_foreign_key "cron_jobs", "organizations"
  add_foreign_key "cron_jobs", "servers"
  add_foreign_key "database_clusters", "organizations"
  add_foreign_key "database_clusters", "servers"
  add_foreign_key "database_pulls", "apps"
  add_foreign_key "database_pulls", "organizations"
  add_foreign_key "database_pulls", "servers"
  add_foreign_key "database_pulls", "users"
  add_foreign_key "databases", "apps"
  add_foreign_key "databases", "database_clusters"
  add_foreign_key "databases", "organizations"
  add_foreign_key "deploy_keys", "apps"
  add_foreign_key "deployments", "apps"
  add_foreign_key "deployments", "scripts"
  add_foreign_key "deployments", "servers"
  add_foreign_key "deployments", "users"
  add_foreign_key "env_variables", "apps"
  add_foreign_key "invitations", "organizations"
  add_foreign_key "invitations", "users", column: "invited_by_id"
  add_foreign_key "mcp_calls", "organizations"
  add_foreign_key "mcp_calls", "users"
  add_foreign_key "memberships", "organizations"
  add_foreign_key "memberships", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "script_runs", "scripts"
  add_foreign_key "script_runs", "servers"
  add_foreign_key "servers", "organizations"
  add_foreign_key "servers", "ssh_keys"
  add_foreign_key "ssh_keys", "organizations"
  add_foreign_key "tool_executions", "messages"
end
