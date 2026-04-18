# frozen_string_literal: true

require "socket"
require "thread"
require "uri"
require "fileutils"

require "rubyd/parser"
require "rubyd/router"
require "rubyd/plugin"
require "rubyd/logger"

module Rubyd
  class Server
    DEFAULT_INDEX = <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>rubyd</title>
        <style>
          :root {
            color-scheme: light dark;
            --bg: #0b1020;
            --fg: #e8ecff;
            --card: rgba(255,255,255,0.08);
            --accent: #6fe3ff;
          }
          @media (prefers-color-scheme: light) {
            :root {
              --bg: #f4f7ff;
              --fg: #18233d;
              --card: rgba(20,35,61,0.08);
              --accent: #006de0;
            }
          }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            min-height: 100vh;
            display: grid;
            place-items: center;
            font-family: "Segoe UI", "Helvetica Neue", sans-serif;
            background: radial-gradient(circle at 20% 20%, var(--card), transparent 40%), var(--bg);
            color: var(--fg);
          }
          main {
            width: min(680px, 92vw);
            padding: 2.25rem;
            border-radius: 18px;
            background: var(--card);
            backdrop-filter: blur(4px);
            border: 1px solid rgba(255,255,255,0.15);
          }
          h1 { margin: 0 0 .65rem; font-size: clamp(2rem, 4vw, 3rem); }
          p { margin: .25rem 0; line-height: 1.6; font-size: 1.05rem; }
          strong { color: var(--accent); }
        </style>
      </head>
      <body>
        <main>
          <h1>Welcome to rubyd</h1>
          <p>If you see this page, <strong>rubyd is working.</strong></p>
        </main>
      </body>
      </html>
    HTML

    attr_reader :router, :config, :logger

    def initialize(config)
      @config = config
      @logger = Logger.new(
        access_log_path: config.access_log,
        error_log_path: config.error_log,
        level: config.log_level
      )
      @router = Router.new
      @plugin_manager = Plugin::Manager.new(server: self, logger: @logger, config: config)
      @queue = Queue.new
      @workers = []
      @running = false
      @reload_requested = false
    end

    def run
      bootstrap_filesystem
      setup_default_routes
      load_plugins
      trap_signals

      @server = TCPServer.new(config.host, config.port)
      @running = true

      logger.info("rubyd listening on #{config.host}:#{config.port}")

      start_workers
      accept_loop
    rescue Interrupt
      shutdown
    rescue StandardError => e
      logger.error("Fatal server error: #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
      shutdown
    end

    def request_reload
      @reload_requested = true
    end

    def shutdown
      return unless @running

      @running = false
      logger.info("Shutdown initiated")
      @server&.close

      @workers.size.times { @queue << :shutdown }
      @workers.each(&:join)

      logger.close
    rescue StandardError => e
      warn("Shutdown error: #{e.class}: #{e.message}")
    end

    private

    def bootstrap_filesystem
      FileUtils.mkdir_p(config.root)
      FileUtils.mkdir_p(config.plugins_dir)
      FileUtils.mkdir_p(config.logs_dir)

      index_path = File.join(config.root, "index.html")
      return if File.exist?(index_path)

      File.write(index_path, DEFAULT_INDEX)
    end

    def setup_default_routes
      router.get("/health") do
        Response.new(
          body: "ok",
          headers: { "Content-Type" => "text/plain; charset=utf-8" }
        )
      end
    end

    def load_plugins
      @plugin_manager.load_all
      @plugin_manager.setup_routes(router)
    end

    def reload_config
      logger.info("Reload requested")
      new_config = Config.load("config.rb")
      @config = new_config
      @reload_requested = false
      logger.info("Configuration reloaded")
    rescue StandardError => e
      @reload_requested = false
      logger.error("Reload failed: #{e.class}: #{e.message}")
    end

    def start_workers
      config.worker_threads.times do
        @workers << Thread.new do
          loop do
            socket = @queue.pop
            break if socket == :shutdown

            handle_connection(socket)
          rescue StandardError => e
            logger.error("Worker error: #{e.class}: #{e.message}")
          ensure
            socket&.close
          end
        end
      end
    end

    def accept_loop
      while @running
        reload_config if @reload_requested

        begin
          readable = IO.select([@server], nil, nil, 0.5)
          next unless readable

          client = @server.accept_nonblock(exception: false)
          next if client == :wait_readable

          @queue << client
        rescue IOError, Errno::EBADF
          break
        rescue StandardError => e
          logger.error("Accept loop error: #{e.class}: #{e.message}")
        end
      end
    ensure
      shutdown
    end

    def handle_connection(socket)
      request = Parser.parse(socket)
      unless request
        socket.write(Response.new(status: 400, body: "Bad Request").to_http)
        return
      end

      @plugin_manager.before_request(request)
      response = process_request(request)
      @plugin_manager.after_response(request, response)

      socket.write(response.to_http)
      log_access(request, response)
    rescue StandardError => e
      logger.error("Request processing error: #{e.class}: #{e.message}")
      socket.write(Response.new(status: 500, body: "Internal Server Error").to_http)
    end

    def process_request(request)
      path = URI(request.path).path
      request.path = path

      routed = router.resolve(request)
      return routed if routed

      serve_static(request)
    rescue URI::InvalidURIError
      Response.new(status: 400, body: "Bad Request")
    end

    def serve_static(request)
      return Response.new(status: 405, body: "Method Not Allowed") unless request.method == "GET"

      relative = request.path == "/" ? "/index.html" : request.path
      full_path = File.expand_path(".#{relative}", config.root)
      root_path = File.expand_path(config.root)

      return Response.new(status: 404, body: "Not Found") unless full_path.start_with?(root_path)
      return Response.new(status: 404, body: "Not Found") unless File.file?(full_path)

      body = File.binread(full_path)
      ext = File.extname(full_path)
      content_type = mime_type(ext)

      Response.new(body: body, headers: { "Content-Type" => content_type })
    end

    def mime_type(ext)
      {
        ".html" => "text/html; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".js" => "application/javascript; charset=utf-8",
        ".json" => "application/json; charset=utf-8",
        ".txt" => "text/plain; charset=utf-8",
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".svg" => "image/svg+xml"
      }.fetch(ext.downcase, "application/octet-stream")
    end

    def log_access(request, response)
      logger.access(
        "#{request.remote_addr} \"#{request.method} #{request.path} #{request.http_version}\" #{response.status}"
      )
    end

    def trap_signals
      Signal.trap("INT") { shutdown }
      Signal.trap("TERM") { shutdown }
      Signal.trap("HUP") { request_reload }
    rescue ArgumentError
      logger.warn("Signal HUP not supported on this platform")
    end
  end
end
