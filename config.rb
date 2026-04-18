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

plugins do
  enable :echo
end
