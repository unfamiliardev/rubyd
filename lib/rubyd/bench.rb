# frozen_string_literal: true

require "socket"
require "thread"

module Rubyd
  class Bench
    def initialize(host:, port:, path:, requests:, concurrency:, stdout: $stdout)
      @host = host
      @port = port
      @path = path
      @requests = requests
      @concurrency = concurrency
      @stdout = stdout
      @latencies = []
      @latency_mutex = Mutex.new
      @errors = 0
      @error_mutex = Mutex.new
    end

    def run
      queue = Queue.new
      @requests.times { |i| queue << i }

      started_at = monotonic_now

      workers = Array.new(@concurrency) do
        Thread.new do
          loop do
            queue.pop(true)
            run_single_request
          rescue ThreadError
            break
          end
        end
      end

      workers.each(&:join)

      elapsed = monotonic_now - started_at
      report(elapsed)
    end

    private

    def run_single_request
      request_started = monotonic_now
      socket = TCPSocket.new(@host, @port)
      socket.write(<<~HTTP.gsub("\n", "\r\n"))
        GET #{@path} HTTP/1.1
        Host: #{@host}
        Connection: close

      HTTP

      status_line = socket.gets
      raise "invalid HTTP response" unless status_line&.start_with?("HTTP/1.1")

      socket.read

      latency_ms = (monotonic_now - request_started) * 1000.0
      @latency_mutex.synchronize { @latencies << latency_ms }
    rescue StandardError
      @error_mutex.synchronize { @errors += 1 }
    ensure
      socket&.close
    end

    def report(elapsed)
      completed = @latencies.length
      avg_latency = completed.zero? ? 0.0 : (@latencies.sum / completed)
      max_latency = completed.zero? ? 0.0 : @latencies.max
      rps = elapsed.zero? ? 0.0 : (completed / elapsed)

      @stdout.puts "Requests: #{@requests}"
      @stdout.puts "Concurrency: #{@concurrency}"
      @stdout.puts "Completed: #{completed}"
      @stdout.puts "Failed: #{@errors}"
      @stdout.puts format("RPS: %.2f", rps)
      @stdout.puts format("Avg Latency: %.2fms", avg_latency)
      @stdout.puts format("Max Latency: %.2fms", max_latency)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
