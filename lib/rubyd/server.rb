# frozen_string_literal: true

require "socket"
require "thread"
require "uri"
require "fileutils"
require "digest"
require "base64"
require "openssl"
require "zlib"
require "stringio"
require "net/http"
require "json"
require "cgi"

require "rubyd/parser"
require "rubyd/router"
require "rubyd/plugin"
require "rubyd/logger"
require "rubyd/php_lite"

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
          <p><strong>Version:</strong> 1.2 "D3rlord3"</p>
          <p><strong>Developed by unfamiliardev</strong></p>
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
        level: config.log_level,
        rotate_size: config.log_rotation_size,
        rotate_keep: config.log_rotation_keep
      )
      @router = Router.new
      @plugin_manager = Plugin::Manager.new(server: self, logger: @logger, config: config)
      @queue = Queue.new
      @workers = []
      @running = false
      @reload_requested = false
      @draining = false
      @active_connections = 0
      @active_mutex = Mutex.new
      @rate_limit = {}
      @rate_limit_mutex = Mutex.new
      @metrics = {
        started_at: Time.now.to_i,
        requests_total: 0,
        bytes_sent: 0,
        status_counts: Hash.new(0),
        latency_ms_sum: 0.0,
        latency_ms_max: 0.0,
        open_connections: 0,
        websocket_upgrades: 0,
        proxied_requests: 0,
        upload_count: 0,
        upload_bytes: 0
      }
      @middleware = [
        method(:enforce_ip_policy),
        method(:enforce_rate_limit),
        method(:enforce_basic_auth),
        method(:handle_protocol_upgrade)
      ]
    end

    def run
      bootstrap_filesystem
      setup_default_routes
      load_plugins
      trap_signals

      @server = build_listener
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
      @draining = true
      logger.info("Shutdown initiated")
      @server&.close

      wait_for_drain

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
      FileUtils.mkdir_p(config.upload_dir)
      FileUtils.mkdir_p(File.join(config.root, "errors"))

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

      router.get("/upload") do
        Response.new(
          body: <<~HTML,
            <!doctype html>
            <html><body>
              <h1>Upload file</h1>
              <form action="/upload" method="post" enctype="multipart/form-data">
                <input type="file" name="file">
                <button type="submit">Upload</button>
              </form>
            </body></html>
          HTML
          headers: { "Content-Type" => "text/html; charset=utf-8" }
        )
      end

      router.post("/upload") do |request|
        handle_upload(request)
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
          next if @draining

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
      increment_connections

      keep_alive_count = 0
      while @running
        request_started = monotonic_now
        request = Parser.parse(socket, timeout: config.keep_alive_timeout)
        break unless request

        if websocket_upgrade_request?(request)
          socket.write(websocket_handshake_response(request).to_http)
          @metrics[:websocket_upgrades] += 1
          websocket_echo_loop(socket)
          break
        end

        response = dispatch_request(request)
        socket.write(response.to_http)
        record_metrics(request_started, response, response.body.bytesize)
        log_access(request, response)

        keep_alive_count += 1
        break unless keep_alive?(request, response, keep_alive_count)
      end
    rescue StandardError => e
      logger.error("Request processing error: #{e.class}: #{e.message}")
      socket.write(Response.new(status: 500, body: "Internal Server Error").to_http)
    ensure
      decrement_connections
    end

    def dispatch_request(request)
      if request.http_version != "HTTP/1.1"
        return Response.new(status: 505, body: "HTTP Version Not Supported")
      end

      @plugin_manager.before_request(request)
      middleware_result = run_middleware(request)
      response = middleware_result || process_request(request)
      @plugin_manager.after_response(request, response)
      response
    end

    def run_middleware(request)
      @middleware.each do |layer|
        response = layer.call(request)
        return response if response
      end
      nil
    end

    def process_request(request)
      uri = URI(request.path)
      request.path = uri.path

      if config.enable_metrics && request.path == config.metrics_path
        return metrics_response
      end

      proxied = reverse_proxy_response(request, query_string: uri.query.to_s)
      return proxied if proxied

      routed = router.resolve(request)
      return routed if routed

      serve_static(request, query_string: uri.query.to_s)
    rescue URI::InvalidURIError
      Response.new(status: 400, body: "Bad Request")
    end

    def serve_static(request, query_string: "")
      host_root = config.root_for_host(request.headers["Host"])
      relative = request.path == "/" ? "/index.html" : request.path
      full_path = File.expand_path(".#{relative}", host_root)
      root_path = File.expand_path(host_root)

      return Response.new(status: 404, body: "Not Found") unless full_path.start_with?(root_path)

      if File.directory?(full_path)
        return directory_listing_response(full_path, request.path) if config.directory_listing

        index_candidate = File.join(full_path, "index.html")
        return Response.new(status: 404, body: "Not Found") unless File.file?(index_candidate)

        full_path = index_candidate
      end

      return custom_error_response(404) unless File.file?(full_path)

      ext = File.extname(full_path)

      if ext == ".php"
        return execute_php(full_path, request: request, query_string: query_string)
      end

      if ext == ".rubyd"
        return Response.new(status: 405, body: "Method Not Allowed") unless request.method == "GET"

        return render_rubyd_template(full_path, request: request, query_string: query_string)
      end

      return Response.new(status: 405, body: "Method Not Allowed") unless %w[GET HEAD].include?(request.method)

      stat = File.stat(full_path)
      etag = %Q("#{Digest::SHA1.hexdigest("#{stat.mtime.to_i}-#{stat.size}")}")
      return Response.new(status: 304, headers: { "ETag" => etag, "Cache-Control" => "public, max-age=#{config.cache_max_age}" }, body: "") if fresh?(request, etag, stat)

      body = File.binread(full_path)
      status = 200
      range_headers = {}

      if request.headers["Range"]
        ranged = apply_range(request.headers["Range"], body)
        return Response.new(status: 416, body: "Range Not Satisfiable") unless ranged

        body = ranged[:body]
        status = 206
        range_headers = { "Content-Range" => ranged[:content_range], "Accept-Ranges" => "bytes" }
      end

      served_length = body.bytesize

      if request.method == "HEAD"
        body = ""
      else
        body, encoding = compress_body(body, request.headers["Accept-Encoding"].to_s)
        range_headers["Content-Encoding"] = encoding if encoding
      end

      content_type = mime_type(ext)

      Response.new(
        status: status,
        body: body,
        headers: {
          "Content-Type" => content_type,
          "ETag" => etag,
          "Last-Modified" => stat.mtime.httpdate,
          "Cache-Control" => "public, max-age=#{config.cache_max_age}",
          "Content-Length" => served_length.to_s
        }.merge(range_headers)
      )
    end

    def execute_php(script_path, request:, query_string:)
      result = PhpLite.render_file(script_path, request: request, query_string: query_string)
      Response.new(status: result.status, headers: result.headers, body: result.body)
    rescue StandardError => e
      logger.error("PHP runtime error for #{script_path}: #{e.class}: #{e.message}")
      Response.new(status: 500, body: "PHP handler error")
    end

    def render_rubyd_template(path, request:, query_string:)
      template = File.read(path)
      vars = {
        "method" => request.method,
        "path" => request.path,
        "query" => query_string.to_s,
        "remote_addr" => request.remote_addr.to_s,
        "time" => Time.now.utc.iso8601
      }

      rendered = template.gsub(/\{\{\s*([a-zA-Z_][a-zA-Z0-9_]*)\s*\}\}/) do
        vars.fetch(Regexp.last_match(1), "")
      end

      Response.new(
        body: rendered,
        headers: { "Content-Type" => "text/html; charset=utf-8" }
      )
    rescue StandardError => e
      logger.error("rubyd template error for #{path}: #{e.class}: #{e.message}")
      Response.new(status: 500, body: "rubyd template error")
    end

    def mime_type(ext)
      {
        ".html" => "text/html; charset=utf-8",
        ".css" => "text/css; charset=utf-8",
        ".js" => "application/javascript; charset=utf-8",
        ".json" => "application/json; charset=utf-8",
        ".txt" => "text/plain; charset=utf-8",
        ".rubyd" => "text/html; charset=utf-8",
        ".png" => "image/png",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".gif" => "image/gif",
        ".svg" => "image/svg+xml"
      }.fetch(ext.downcase, "application/octet-stream")
    end

    def keep_alive?(request, response, count)
      return false if @draining
      return false if count >= config.max_keep_alive_requests
      return false if request.headers["Connection"].to_s.casecmp("close").zero?

      response.headers["Connection"] = "keep-alive"
      true
    end

    def wait_for_drain
      100.times do
        break if active_connections.zero?

        sleep 0.05
      end
    end

    def active_connections
      @active_mutex.synchronize { @active_connections }
    end

    def increment_connections
      @active_mutex.synchronize do
        @active_connections += 1
        @metrics[:open_connections] = @active_connections
      end
    end

    def decrement_connections
      @active_mutex.synchronize do
        @active_connections -= 1 if @active_connections.positive?
        @metrics[:open_connections] = @active_connections
      end
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def record_metrics(started, response, bytes)
      duration_ms = (monotonic_now - started) * 1000.0
      @metrics[:requests_total] += 1
      @metrics[:bytes_sent] += bytes
      @metrics[:status_counts][response.status] += 1
      @metrics[:latency_ms_sum] += duration_ms
      @metrics[:latency_ms_max] = [@metrics[:latency_ms_max], duration_ms].max
    end

    def metrics_response
      avg = @metrics[:requests_total].zero? ? 0.0 : (@metrics[:latency_ms_sum] / @metrics[:requests_total])
      payload = {
        started_at: @metrics[:started_at],
        uptime_seconds: Time.now.to_i - @metrics[:started_at],
        requests_total: @metrics[:requests_total],
        open_connections: @metrics[:open_connections],
        status_counts: @metrics[:status_counts],
        bytes_sent: @metrics[:bytes_sent],
        latency_ms_avg: avg.round(3),
        latency_ms_max: @metrics[:latency_ms_max].round(3),
        websocket_upgrades: @metrics[:websocket_upgrades],
        proxied_requests: @metrics[:proxied_requests],
        upload_count: @metrics[:upload_count],
        upload_bytes: @metrics[:upload_bytes]
      }

      Response.new(body: JSON.pretty_generate(payload), headers: { "Content-Type" => "application/json; charset=utf-8" })
    end

    def enforce_ip_policy(request)
      ip = request.remote_addr.to_s
      if config.ip_blacklist.include?(ip)
        return Response.new(status: 403, body: "Forbidden")
      end

      if config.ip_whitelist.any? && !config.ip_whitelist.include?(ip)
        return Response.new(status: 403, body: "Forbidden")
      end

      nil
    end

    def enforce_rate_limit(request)
      return nil if config.rate_limit_max <= 0

      now = monotonic_now
      ip = request.remote_addr.to_s
      over = false
      @rate_limit_mutex.synchronize do
        bucket = (@rate_limit[ip] ||= [])
        cutoff = now - config.rate_limit_window
        bucket.reject! { |entry| entry < cutoff }
        bucket << now
        over = bucket.length > config.rate_limit_max
      end

      over ? Response.new(status: 429, body: "Too Many Requests") : nil
    end

    def enforce_basic_auth(request)
      return nil unless config.basic_auth_enabled
      return nil if request.path == "/health"

      auth = request.headers["Authorization"].to_s
      scheme, token = auth.split(" ", 2)
      unless scheme.to_s.casecmp("basic").zero? && token
        return unauthorized_response
      end

      decoded = Base64.decode64(token.to_s)
      user, pass = decoded.split(":", 2)
      return nil if user == config.basic_auth_username && pass == config.basic_auth_password

      unauthorized_response
    rescue StandardError
      unauthorized_response
    end

    def unauthorized_response
      Response.new(
        status: 401,
        body: "Unauthorized",
        headers: { "WWW-Authenticate" => %(Basic realm="#{config.basic_auth_realm}") }
      )
    end

    def handle_protocol_upgrade(request)
      if request.headers["Upgrade"].to_s.downcase == "h2c"
        return Response.new(status: 426, body: "Upgrade Required", headers: { "Upgrade" => "h2c" })
      end

      nil
    end

    def websocket_upgrade_request?(request)
      upgrade = request.headers["Upgrade"].to_s.downcase
      connection = request.headers["Connection"].to_s.downcase
      key = request.headers["Sec-WebSocket-Key"].to_s

      request.method == "GET" && upgrade == "websocket" && connection.include?("upgrade") && !key.empty?
    end

    def websocket_handshake_response(request)
      key = request.headers["Sec-WebSocket-Key"].to_s
      accept = Base64.strict_encode64(
        Digest::SHA1.digest("#{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11")
      )

      Response.new(
        status: 101,
        body: "",
        headers: {
          "Upgrade" => "websocket",
          "Connection" => "Upgrade",
          "Sec-WebSocket-Accept" => accept,
          "Content-Length" => "0"
        }
      )
    end

    def websocket_echo_loop(socket)
      loop do
        header = socket.read(2)
        break if header.nil? || header.bytesize < 2

        b1, b2 = header.bytes
        opcode = (b1 & 0x0f)
        masked = (b2 & 0x80) != 0
        length = (b2 & 0x7f)

        if length == 126
          ext = socket.read(2)
          break unless ext && ext.bytesize == 2
          length = ext.unpack1("n")
        elsif length == 127
          ext = socket.read(8)
          break unless ext && ext.bytesize == 8
          length = ext.unpack1("Q>")
        end

        mask = masked ? socket.read(4).to_s.bytes : []
        payload = socket.read(length).to_s.bytes
        break if payload.bytesize < length

        if masked
          payload = payload.each_with_index.map { |byte, i| byte ^ mask[i % 4] }
        end

        case opcode
        when 0x8
          socket.write([0x88, 0x00].pack("C*") )
          break
        when 0x9
          write_websocket_frame(socket, 0xA, payload.pack("C*"))
        when 0x1
          write_websocket_frame(socket, 0x1, payload.pack("C*"))
        end
      end
    rescue StandardError => e
      logger.error("WebSocket error: #{e.class}: #{e.message}")
    end

    def write_websocket_frame(socket, opcode, data)
      payload = data.to_s.b
      bytes = [0x80 | opcode]

      if payload.bytesize <= 125
        bytes << payload.bytesize
      elsif payload.bytesize <= 65_535
        bytes << 126
        bytes.concat([payload.bytesize].pack("n").bytes)
      else
        bytes << 127
        bytes.concat([payload.bytesize].pack("Q>").bytes)
      end

      socket.write(bytes.pack("C*") + payload)
    end

    def reverse_proxy_response(request, query_string:)
      rule = config.reverse_proxy_rules.find { |entry| request.path.start_with?(entry[:path_prefix]) }
      return nil unless rule

      upstream = URI(rule[:upstream])
      path = request.path.sub(rule[:path_prefix], "")
      path = "/" if path.empty?
      path += "?#{query_string}" unless query_string.to_s.empty?

      http = Net::HTTP.new(upstream.host, upstream.port)
      http.use_ssl = (upstream.scheme == "https")

      klass = case request.method
              when "POST" then Net::HTTP::Post
              when "PUT" then Net::HTTP::Put
              when "DELETE" then Net::HTTP::Delete
              else Net::HTTP::Get
              end
      upstream_req = klass.new(path)
      request.headers.each do |k, v|
        next if k.casecmp("host").zero?

        upstream_req[k] = v
      end
      upstream_req.body = request.body if %w[POST PUT].include?(request.method)

      upstream_res = http.request(upstream_req)
      @metrics[:proxied_requests] += 1

      headers = {}
      upstream_res.each_header { |k, v| headers[k.split("-").map(&:capitalize).join("-")] = v }
      Response.new(status: upstream_res.code.to_i, headers: headers, body: upstream_res.body.to_s)
    rescue StandardError => e
      logger.error("Proxy upstream error: #{e.class}: #{e.message}")
      Response.new(status: 502, body: "Bad Gateway")
    end

    def fresh?(request, etag, stat)
      return true if request.headers["If-None-Match"].to_s == etag

      ims = request.headers["If-Modified-Since"].to_s
      return false if ims.empty?

      Time.httpdate(ims) >= stat.mtime
    rescue StandardError
      false
    end

    def apply_range(range_header, body)
      m = range_header.to_s.match(/\Abytes=(\d*)-(\d*)\z/)
      return nil unless m

      from_s = m[1]
      to_s = m[2]
      size = body.bytesize
      return nil if size.zero?

      if from_s.empty?
        length = to_s.to_i
        return nil if length <= 0

        from = [size - length, 0].max
        to = size - 1
      else
        from = from_s.to_i
        to = to_s.empty? ? size - 1 : to_s.to_i
      end

      return nil if from.negative? || to < from || from >= size
      to = [to, size - 1].min
      chunk = body.byteslice(from..to)
      { body: chunk, content_range: "bytes #{from}-#{to}/#{size}" }
    end

    def compress_body(body, accept_encoding)
      return [body, nil] if body.nil? || body.empty?

      accepted = accept_encoding.to_s.downcase

      if accepted.include?("br")
        begin
          require "brotli"
          return [Brotli.deflate(body), "br"]
        rescue LoadError
        end
      end

      return [body, nil] unless accepted.include?("gzip")

      io = StringIO.new
      gz = Zlib::GzipWriter.new(io)
      gz.write(body)
      gz.close
      [io.string, "gzip"]
    end

    def directory_listing_response(path, request_path)
      entries = Dir.children(path).sort
      items = entries.map do |entry|
        clean = request_path.end_with?("/") ? request_path : "#{request_path}/"
        %(<li><a href="#{CGI.escapeHTML(clean + entry)}">#{CGI.escapeHTML(entry)}</a></li>)
      end.join

      Response.new(
        body: "<!doctype html><html><body><h1>Index of #{CGI.escapeHTML(request_path)}</h1><ul>#{items}</ul></body></html>",
        headers: { "Content-Type" => "text/html; charset=utf-8" }
      )
    end

    def handle_upload(request)
      return Response.new(status: 413, body: "Payload Too Large") if request.body.bytesize > config.max_upload_size

      content_type = request.headers["Content-Type"].to_s
      boundary = content_type[/boundary=([^;]+)/, 1]
      return Response.new(status: 400, body: "Missing multipart boundary") if boundary.to_s.empty?

      file_part = extract_multipart_file(request.body, boundary)
      return Response.new(status: 400, body: "No file part") unless file_part

      filename = sanitize_filename(file_part[:filename])
      path = File.join(config.upload_dir, filename)
      FileUtils.mkdir_p(config.upload_dir)
      File.binwrite(path, file_part[:content])

      @metrics[:upload_count] += 1
      @metrics[:upload_bytes] += file_part[:content].bytesize

      Response.new(
        status: 201,
        body: "Uploaded #{filename} (#{file_part[:content].bytesize} bytes)",
        headers: { "Content-Type" => "text/plain; charset=utf-8" }
      )
    end

    def extract_multipart_file(body, boundary)
      marker = "--#{boundary}"
      parts = body.split(marker)
      parts.each do |part|
        next unless part.include?("Content-Disposition")
        next unless part.include?("filename=")

        header, content = part.split("\r\n\r\n", 2)
        next unless header && content

        filename = header[/filename=\"([^\"]+)\"/, 1]
        next if filename.to_s.empty?

        payload = content.sub(/\r\n--\z/, "").sub(/\r\n\z/, "")
        return { filename: filename, content: payload }
      end
      nil
    end

    def sanitize_filename(name)
      cleaned = File.basename(name.to_s)
      cleaned.gsub(/[^a-zA-Z0-9._-]/, "_")
    end

    def custom_error_response(status)
      error_path = File.join(config.root, "errors", "#{status}.html")
      return Response.new(status: status, body: Response::REASONS[status]) unless File.file?(error_path)

      Response.new(
        status: status,
        body: File.read(error_path),
        headers: { "Content-Type" => "text/html; charset=utf-8" }
      )
    end

    def build_listener
      tcp = TCPServer.new(config.host, config.port)
      return tcp unless config.tls_enabled

      ctx = OpenSSL::SSL::SSLContext.new
      ctx.cert = OpenSSL::X509::Certificate.new(File.read(config.tls_cert))
      ctx.key = OpenSSL::PKey.read(File.read(config.tls_key))
      OpenSSL::SSL::SSLServer.new(tcp, ctx)
    rescue StandardError => e
      logger.error("TLS setup failed (falling back to TCP): #{e.class}: #{e.message}")
      tcp
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
