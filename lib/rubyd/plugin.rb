# frozen_string_literal: true

module Rubyd
  module Plugin
    @registry = {}

    def self.register(name, klass)
      @registry[name.to_sym] = klass
    end

    def self.registry
      @registry
    end

    class Base
      def initialize(server)
        @server = server
      end

      def setup(router); end

      def before_request(_request); end

      def after_response(_request, _response); end
    end

    class Manager
      def initialize(server:, logger:, config:)
        @server = server
        @logger = logger
        @config = config
        @instances = []
      end

      def load_all
        Dir.glob(File.join(@config.plugins_dir, "*.rb")).sort.each do |file|
          load file
        rescue StandardError => e
          @logger.error("Plugin load error (#{file}): #{e.class}: #{e.message}")
        end

        Plugin.registry.each do |name, klass|
          next unless @config.plugin_enabled?(name)

          instance = klass.new(@server)
          @instances << instance
          @logger.info("Loaded plugin #{name}")
        rescue StandardError => e
          @logger.error("Plugin init error (#{name}): #{e.class}: #{e.message}")
        end
      end

      def setup_routes(router)
        @instances.each do |plugin|
          plugin.setup(router)
        rescue StandardError => e
          @logger.error("Plugin setup error (#{plugin.class}): #{e.class}: #{e.message}")
        end
      end

      def before_request(request)
        @instances.each do |plugin|
          plugin.before_request(request)
        rescue StandardError => e
          @logger.error("Plugin before_request error (#{plugin.class}): #{e.class}: #{e.message}")
        end
      end

      def after_response(request, response)
        @instances.each do |plugin|
          plugin.after_response(request, response)
        rescue StandardError => e
          @logger.error("Plugin after_response error (#{plugin.class}): #{e.class}: #{e.message}")
        end
      end
    end
  end
end
