# rubyd configuration DSL

port 9292
host "0.0.0.0"
root "www"
pid_file "rubyd.pid"
plugins_dir "plugins"
logs_dir "logs"
access_log "logs/access.log"
error_log "logs/error.log"
log_level :info
worker_threads 8
keep_alive_timeout 5.0
max_keep_alive_requests 50

directory_listing true
cache_max_age 60
rate_limit window: 1.0, max: 120

upload_dir "uploads"
max_upload_size 20_000_000

enable_metrics true
metrics_path "/metrics"

log_rotation size_bytes: 10_000_000, keep: 5

# Uncomment to secure server with basic auth
# basic_auth username: "admin", password: "change-me", realm: "rubyd"

# Uncomment to enable TLS when certs are available
# tls enabled: true, cert: "certs/server.crt", key: "certs/server.key"

# Reverse proxy example
# reverse_proxy path_prefix: "/api", upstream: "http://127.0.0.1:3000"

# Virtual host example
# virtual_host host: "site.local", root: "www/site"

plugins do
  enable :echo
end
