# frozen_string_literal: true

require "set"

module Rubyd
  class Config
    VirtualHost = Struct.new(:host, :root, keyword_init: true)

    class PluginSettings
      attr_reader :enabled, :disabled

      def initialize
        @enabled = Set.new
        @disabled = Set.new
      end

      def enable(name)
        @enabled << name.to_sym
      end

      def disable(name)
        @disabled << name.to_sym
      end
    end

    class DSL
      attr_reader :config

      def initialize
        @config = Config.new
      end

      def port(value)
        @config.port = Integer(value)
      end

      def host(value)
        @config.host = value.to_s
      end

      def root(path)
        @config.root = path.to_s
      end

      def pid_file(path)
        @config.pid_file = path.to_s
      end

      def plugins_dir(path)
        @config.plugins_dir = path.to_s
      end

      def logs_dir(path)
        @config.logs_dir = path.to_s
      end

      def access_log(path)
        @config.access_log = path.to_s
      end

      def error_log(path)
        @config.error_log = path.to_s
      end

      def log_level(value)
        @config.log_level = value.to_sym
      end

      def worker_threads(value)
        @config.worker_threads = Integer(value)
      end

      def keep_alive_timeout(value)
        @config.keep_alive_timeout = value.to_f
      end

      def max_keep_alive_requests(value)
        @config.max_keep_alive_requests = Integer(value)
      end

      def directory_listing(value)
        @config.directory_listing = !!value
      end

      def cache_max_age(value)
        @config.cache_max_age = Integer(value)
      end

      def rate_limit(window:, max:)
        @config.rate_limit_window = window.to_f
        @config.rate_limit_max = Integer(max)
      end

      def allow_ip(*ips)
        @config.ip_whitelist.concat(ips.flatten.map(&:to_s))
      end

      def block_ip(*ips)
        @config.ip_blacklist.concat(ips.flatten.map(&:to_s))
      end

      def upload_dir(path)
        @config.upload_dir = path.to_s
      end

      def max_upload_size(bytes)
        @config.max_upload_size = Integer(bytes)
      end

      def metrics_path(path)
        @config.metrics_path = path.to_s
      end

      def enable_metrics(value)
        @config.enable_metrics = !!value
      end

      def basic_auth(username:, password:, realm: "rubyd")
        @config.basic_auth_enabled = true
        @config.basic_auth_username = username.to_s
        @config.basic_auth_password = password.to_s
        @config.basic_auth_realm = realm.to_s
      end

      def disable_basic_auth
        @config.basic_auth_enabled = false
      end

      def tls(enabled: true, cert:, key:)
        @config.tls_enabled = !!enabled
        @config.tls_cert = cert.to_s
        @config.tls_key = key.to_s
      end

      def reverse_proxy(path_prefix:, upstream:)
        @config.reverse_proxy_rules << { path_prefix: path_prefix.to_s, upstream: upstream.to_s }
      end

      def virtual_host(host:, root:)
        @config.virtual_hosts << VirtualHost.new(host: host.to_s, root: root.to_s)
      end

      def log_rotation(size_bytes:, keep:)
        @config.log_rotation_size = Integer(size_bytes)
        @config.log_rotation_keep = Integer(keep)
      end

      def plugins(&block)
        @config.plugin_settings.instance_eval(&block)
      end
    end

    attr_accessor :port, :host, :root, :pid_file, :plugins_dir, :logs_dir,
                  :access_log, :error_log, :log_level, :worker_threads,
                  :keep_alive_timeout, :max_keep_alive_requests, :directory_listing,
                  :cache_max_age, :rate_limit_window, :rate_limit_max,
                  :upload_dir, :max_upload_size, :metrics_path, :enable_metrics,
                  :basic_auth_enabled, :basic_auth_username, :basic_auth_password,
                  :basic_auth_realm, :tls_enabled, :tls_cert, :tls_key,
                  :log_rotation_size, :log_rotation_keep
    attr_reader :reverse_proxy_rules, :virtual_hosts, :ip_whitelist, :ip_blacklist
    attr_reader :plugin_settings

    def initialize
      @port = 9292
      @host = "0.0.0.0"
      @root = "www"
      @pid_file = "rubyd.pid"
      @plugins_dir = "plugins"
      @logs_dir = "logs"
      @access_log = "logs/access.log"
      @error_log = "logs/error.log"
      @log_level = :info
      @worker_threads = 8
      @keep_alive_timeout = 5.0
      @max_keep_alive_requests = 50
      @directory_listing = false
      @cache_max_age = 30
      @rate_limit_window = 1.0
      @rate_limit_max = 60
      @ip_whitelist = []
      @ip_blacklist = []
      @upload_dir = "uploads"
      @max_upload_size = 10 * 1024 * 1024
      @metrics_path = "/metrics"
      @enable_metrics = true
      @basic_auth_enabled = false
      @basic_auth_username = ""
      @basic_auth_password = ""
      @basic_auth_realm = "rubyd"
      @tls_enabled = false
      @tls_cert = ""
      @tls_key = ""
      @reverse_proxy_rules = []
      @virtual_hosts = []
      @log_rotation_size = 10 * 1024 * 1024
      @log_rotation_keep = 5
      @plugin_settings = PluginSettings.new
    end

    def self.load(path)
      dsl = DSL.new
      dsl.instance_eval(File.read(path), path)
      dsl.config
    end

    def plugin_enabled?(name)
      key = name.to_sym
      return false if plugin_settings.disabled.include?(key)
      return true if plugin_settings.enabled.empty?

      plugin_settings.enabled.include?(key)
    end

    def root_for_host(host_header)
      host = host_header.to_s.split(":", 2).first
      match = @virtual_hosts.find { |vh| vh.host.casecmp(host).zero? }
      match ? match.root : @root
    end
  end
end
