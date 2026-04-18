# frozen_string_literal: true

# Example plugin to demonstrate route registration and response mutation.
class EchoPlugin < Rubyd::Plugin::Base
  def setup(router)
    router.get("/echo") do |request|
      message = request.headers["X-Echo"] || "rubyd"
      Rubyd::Response.new(
        headers: { "Content-Type" => "text/plain; charset=utf-8" },
        body: "echo: #{message}"
      )
    end
  end

  def after_response(request, response)
    response.headers["X-Rubyd-Plugin"] = "EchoPlugin" if request.path == "/echo"
  end
end

Rubyd::Plugin.register(:echo, EchoPlugin)
