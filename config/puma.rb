# This configuration file will be evaluated by Puma. The top-level methods that
# are invoked here are part of Puma's configuration DSL. For more information
# about methods provided by the DSL, see https://puma.io/puma/Puma/DSL.html.

threads_count = ENV.fetch("RAILS_MAX_THREADS", 3)
threads threads_count, threads_count

# Specifies the `port` that Puma will listen on to receive requests; default is 3030.
port ENV.fetch("PORT", 3030)

# Production: fork worker processes for better memory usage and throughput.
# Development runs single-process to avoid macOS fork + Obj-C runtime crashes.
workers ENV.fetch("WEB_CONCURRENCY", 0)
preload_app! if ENV.fetch("WEB_CONCURRENCY", "0").to_i > 0
worker_timeout ENV.fetch("WORKER_TIMEOUT", 30).to_i if ENV.fetch("WEB_CONCURRENCY", "0").to_i > 0

# Allow puma to be restarted by `bin/rails restart` command.
plugin :tmp_restart

# Run the Solid Queue supervisor inside of Puma for single-server deployments.
# Only used in production (set via deploy.yml). Development uses :async adapter.
plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]

# Specify the PID file. Defaults to tmp/pids/server.pid in development.
# In other environments, only set the PID file if requested.
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]
