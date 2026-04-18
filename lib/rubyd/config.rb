# frozen_string_literal: true

require "set"

module Rubyd
  class Config
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

      def plugins(&block)
        @config.plugin_settings.instance_eval(&block)
      end
    end

    attr_accessor :port, :host, :root, :pid_file, :plugins_dir, :logs_dir,
                  :access_log, :error_log, :log_level, :worker_threads
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
  end
end
