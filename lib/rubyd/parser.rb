# frozen_string_literal: true

module Rubyd
  Request = Struct.new(:method, :path, :http_version, :headers, :body, :remote_addr, keyword_init: true)

  class Response
    REASONS = {
      101 => "Switching Protocols",
      200 => "OK",
      206 => "Partial Content",
      301 => "Moved Permanently",
      302 => "Found",
      304 => "Not Modified",
      400 => "Bad Request",
      401 => "Unauthorized",
      403 => "Forbidden",
      201 => "Created",
      204 => "No Content",
      404 => "Not Found",
      405 => "Method Not Allowed",
      408 => "Request Timeout",
      413 => "Payload Too Large",
      416 => "Range Not Satisfiable",
      426 => "Upgrade Required",
      429 => "Too Many Requests",
      500 => "Internal Server Error",
      502 => "Bad Gateway",
      503 => "Service Unavailable",
      505 => "HTTP Version Not Supported"
    }.freeze

    attr_accessor :status, :headers, :body

    def initialize(status: 200, headers: {}, body: "")
      @status = status
      @headers = {
        "Content-Type" => "text/plain; charset=utf-8",
        "Connection" => "close"
      }.merge(headers)
      @body = body.to_s
    end

    def to_http
      @headers["Content-Length"] ||= @body.bytesize.to_s
      lines = ["HTTP/1.1 #{@status} #{REASONS.fetch(@status, "Unknown")}"]
      @headers.each { |k, v| lines << "#{k}: #{v}" }
      lines << ""
      lines << @body
      lines.join("\r\n")
    end
  end

  class Parser
    MAX_HEADER_BYTES = 16 * 1024

    def self.parse(socket, timeout: 5)
      header_text, buffered_body = read_headers(socket, timeout: timeout)
      return nil if header_text.nil? || header_text.empty?

      lines = header_text.split("\r\n")
      request_line = lines.shift
      method, path, version = request_line.to_s.split(" ", 3)
      return nil unless method && path && version

      headers = {}
      lines.each do |line|
        next if line.empty?

        key, value = line.split(":", 2)
        return nil unless key && value

        headers[key.strip] = value.strip
      end

      body = ""
      content_length = headers["Content-Length"].to_i
      if content_length.positive?
        body = buffered_body.to_s
        remaining = content_length - body.bytesize
        body << socket.read(remaining).to_s if remaining.positive?
        body = body.byteslice(0, content_length)
      end

      Request.new(
        method: method,
        path: path,
        http_version: version,
        headers: headers,
        body: body,
        remote_addr: (socket.peeraddr(false)[3] rescue "unknown")
      )
    end

    def self.read_headers(socket, timeout:)
      buffer = +""

      loop do
        ready = IO.select([socket], nil, nil, timeout)
        return nil unless ready

        chunk = socket.recv(1024)
        return nil if chunk.nil? || chunk.empty?

        buffer << chunk
        if buffer.include?("\r\n\r\n")
          header_text, buffered_body = buffer.split("\r\n\r\n", 2)
          return [header_text, buffered_body]
        end
        return nil if buffer.bytesize > MAX_HEADER_BYTES
      end
    end

    private_class_method :read_headers
  end
end
