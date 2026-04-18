# frozen_string_literal: true

require "cgi"
require "time"
require "uri"

module Rubyd
  class PhpLite
    RenderResult = Struct.new(:status, :headers, :body, keyword_init: true)

    def self.render_file(path, request:, query_string:)
      new(request: request, query_string: query_string).render_file(path)
    end

    def initialize(request:, query_string:)
      @request = request
      @headers = {}
      @vars = {}
      @output = +""

      @get_params = URI.decode_www_form(query_string.to_s).each_with_object({}) do |(k, v), memo|
        memo[k] = v
      end

      @server_vars = {
        "REQUEST_METHOD" => request.method,
        "REQUEST_URI" => request.path,
        "QUERY_STRING" => query_string.to_s,
        "REMOTE_ADDR" => request.remote_addr.to_s,
        "SERVER_PROTOCOL" => request.http_version
      }
    end

    def render_file(path)
      source = File.read(path)
      cursor = 0

      source.to_enum(:scan, /<\?(php|=)?(.*?)\?>/m).each do
        match = Regexp.last_match
        @output << source[cursor...match.begin(0)]

        tag = match[1]
        code = match[2].to_s

        if tag == "="
          @output << evaluate_expression(code).to_s
        else
          execute_block(code)
        end

        cursor = match.end(0)
      end

      @output << source[cursor..]

      RenderResult.new(
        status: 200,
        headers: default_headers.merge(@headers),
        body: @output
      )
    end

    private

    def default_headers
      { "Content-Type" => "text/html; charset=utf-8" }
    end

    def execute_block(code)
      split_top_level(code, ";").each do |statement|
        execute_statement(statement.strip)
      end
    end

    def execute_statement(statement)
      return if statement.empty?

      if (m = statement.match(/\Aheader\s*\((.+)\)\z/m))
        apply_header(evaluate_expression(m[1]).to_s)
        return
      end

      if (m = statement.match(/\Aecho\s+(.+)\z/m))
        @output << evaluate_expression(m[1]).to_s
        return
      end

      if (m = statement.match(/\A\$([a-zA-Z_][a-zA-Z0-9_]*)\s*=\s*(.+)\z/m))
        @vars[m[1]] = evaluate_expression(m[2])
        return
      end

      raise ArgumentError, "Unsupported PHP statement: #{statement}"
    end

    def apply_header(header_line)
      key, value = header_line.split(":", 2)
      return unless key && value

      @headers[key.strip] = value.strip
    end

    def evaluate_expression(expression)
      expr = expression.to_s.strip
      return "" if expr.empty?

      expr = unwrap_parentheses(expr)

      if (parts = split_operator(expr, "??"))
        left = evaluate_expression(parts[0])
        return left unless left.nil?

        return evaluate_expression(parts[1])
      end

      if (parts = split_operator(expr, "."))
        return evaluate_expression(parts[0]).to_s + evaluate_expression(parts[1]).to_s
      end

      if (m = expr.match(/\A([a-zA-Z_][a-zA-Z0-9_]*)\s*\((.*)\)\z/m))
        return call_function(m[1], split_function_args(m[2]))
      end

      return parse_string(expr) if quoted?(expr)
      return parse_number(expr) if number?(expr)
      return constant_value(expr) if constant?(expr)
      return read_superglobal(expr) if superglobal?(expr)
      return read_variable(expr) if variable?(expr)

      expr
    end

    def split_function_args(arg_text)
      split_top_level(arg_text.to_s, ",").map { |arg| arg.strip }
    end

    def call_function(name, args)
      case name
      when "gmdate"
        fmt = evaluate_expression(args[0]).to_s
        fmt == "c" ? Time.now.utc.iso8601 : Time.now.utc.strftime(fmt)
      when "htmlspecialchars"
        CGI.escapeHTML(evaluate_expression(args[0]).to_s)
      else
        raise ArgumentError, "Unsupported PHP function: #{name}"
      end
    end

    def split_operator(expr, operator)
      parts = split_top_level(expr, operator)
      return nil if parts.length < 2

      [parts[0], parts[1..].join(operator)]
    end

    def split_top_level(text, delimiter)
      return [] if text.nil? || text.empty?

      parts = []
      token = +""
      depth = 0
      quote = nil
      escape = false
      i = 0

      while i < text.length
        ch = text[i]

        if quote
          token << ch
          if escape
            escape = false
          elsif ch == "\\"
            escape = true
          elsif ch == quote
            quote = nil
          end
          i += 1
          next
        end

        if ch == "'" || ch == '"'
          quote = ch
          token << ch
          i += 1
          next
        end

        if ch == "("
          depth += 1
          token << ch
          i += 1
          next
        end

        if ch == ")"
          depth -= 1 if depth.positive?
          token << ch
          i += 1
          next
        end

        if depth.zero? && text[i, delimiter.length] == delimiter
          parts << token
          token = +""
          i += delimiter.length
          next
        end

        token << ch
        i += 1
      end

      parts << token
      parts
    end

    def unwrap_parentheses(expr)
      loop do
        trimmed = expr.strip
        break trimmed unless trimmed.start_with?("(") && trimmed.end_with?(")")

        inner = trimmed[1...-1]
        break trimmed unless balanced_parentheses?(inner)

        expr = inner
      end
    end

    def balanced_parentheses?(text)
      depth = 0
      quote = nil
      escape = false

      text.each_char do |ch|
        if quote
          if escape
            escape = false
            next
          end

          if ch == "\\"
            escape = true
          elsif ch == quote
            quote = nil
          end

          next
        end

        if ch == "'" || ch == '"'
          quote = ch
          next
        end

        depth += 1 if ch == "("
        depth -= 1 if ch == ")"
        return false if depth.negative?
      end

      depth.zero? && quote.nil?
    end

    def parse_string(expr)
      body = expr[1...-1]
      if expr.start_with?("\"")
        body.gsub(/\\([\\\"nrt])/) do
          case Regexp.last_match(1)
          when "n" then "\n"
          when "r" then "\r"
          when "t" then "\t"
          else Regexp.last_match(1)
          end
        end
      else
        body.gsub("\\'", "'").gsub("\\\\", "\\")
      end
    end

    def parse_number(expr)
      expr.include?(".") ? expr.to_f : expr.to_i
    end

    def constant?(expr)
      %w[null true false ENT_QUOTES].include?(expr)
    end

    def constant_value(expr)
      case expr
      when "null" then nil
      when "true" then true
      when "false" then false
      when "ENT_QUOTES" then :ent_quotes
      end
    end

    def superglobal?(expr)
      expr.start_with?("$_GET[") || expr.start_with?("$_SERVER[")
    end

    def read_superglobal(expr)
      if (m = expr.match(/\A\$_GET\[(.+)\]\z/m))
        key = evaluate_expression(m[1]).to_s
        return @get_params[key]
      end

      if (m = expr.match(/\A\$_SERVER\[(.+)\]\z/m))
        key = evaluate_expression(m[1]).to_s
        return @server_vars[key]
      end

      nil
    end

    def variable?(expr)
      expr.match?(/\A\$[a-zA-Z_][a-zA-Z0-9_]*\z/)
    end

    def read_variable(expr)
      @vars[expr.delete_prefix("$")]
    end

    def quoted?(expr)
      (expr.start_with?("\"") && expr.end_with?("\"")) ||
        (expr.start_with?("'") && expr.end_with?("'"))
    end

    def number?(expr)
      expr.match?(/\A\d+(\.\d+)?\z/)
    end
  end
end
