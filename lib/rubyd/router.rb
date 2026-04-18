# frozen_string_literal: true

module Rubyd
  class Router
    def initialize
      @routes = Hash.new { |h, k| h[k] = {} }
    end

    def get(path, &block)
      route("GET", path, &block)
    end

    def post(path, &block)
      route("POST", path, &block)
    end

    def route(method, path, &block)
      @routes[method][path] = block
    end

    def resolve(request)
      handler = @routes[request.method][request.path]
      return nil unless handler

      result = handler.call(request)
      return result if result.is_a?(Response)

      Response.new(body: result.to_s)
    end
  end
end
