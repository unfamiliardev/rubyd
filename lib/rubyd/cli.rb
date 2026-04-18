# frozen_string_literal: true

require "rbconfig"
require "optparse"
require "fileutils"

require "rubyd/config"
require "rubyd/server"
require "rubyd/bench"

module Rubyd
  class CLI
    def initialize(argv, stdout: $stdout, stderr: $stderr)
      @argv = argv.dup
      @stdout = stdout
      @stderr = stderr
    end

    def run
      command = @argv.shift

      case command
      when "start" then start
      when "stop" then stop
      when "restart" then restart
      when "reload" then reload
      when "status" then status
      when "bench" then bench
      when "__serve__" then serve
      else
        usage
        1
      end
    end

    private

    def usage
      @stdout.puts <<~TXT
        Usage: rubyd <command>

        Commands:
          start    Start rubyd in background
          stop     Stop rubyd gracefully
          restart  Restart rubyd
          reload   Reload config and plugins
          status   Show if rubyd is running
          bench    Run built-in benchmark client
      TXT
    end

    def start
      config = load_config
      running_pid = running_pid(config.pid_file)
      if running_pid
        @stdout.puts "rubyd is already running (pid #{running_pid})"
        return 0
      end

      FileUtils.mkdir_p(config.logs_dir)

      command = [
        RbConfig.ruby,
        File.expand_path("../../bin/rubyd", __dir__),
        "__serve__"
      ]

      pid = Process.spawn(*command, out: File.join(config.logs_dir, "rubyd.out.log"), err: File.join(config.logs_dir, "rubyd.err.log"))
      Process.detach(pid)

      wait_for_start(config.pid_file, pid)
      @stdout.puts "rubyd started"
      0
    rescue StandardError => e
      @stderr.puts "start failed: #{e.class}: #{e.message}"
      1
    end

    def stop
      config = load_config
      pid = running_pid(config.pid_file)

      unless pid
        @stdout.puts "rubyd is not running"
        return 0
      end

      Process.kill("TERM", pid)
      wait_for_stop(pid)
      File.delete(config.pid_file) if File.exist?(config.pid_file)

      @stdout.puts "rubyd stopped"
      0
    rescue StandardError => e
      @stderr.puts "stop failed: #{e.class}: #{e.message}"
      1
    end

    def restart
      stop
      sleep 0.2
      start
    end

    def reload
      config = load_config
      pid = running_pid(config.pid_file)

      unless pid
        @stdout.puts "rubyd is not running"
        return 1
      end

      Process.kill("HUP", pid)
      @stdout.puts "reload signal sent"
      0
    rescue Errno::EINVAL, NotImplementedError
      @stderr.puts "reload is not supported on this platform"
      1
    rescue StandardError => e
      @stderr.puts "reload failed: #{e.class}: #{e.message}"
      1
    end

    def status
      config = load_config
      pid = running_pid(config.pid_file)

      if pid
        @stdout.puts "rubyd is running (pid #{pid})"
        0
      else
        @stdout.puts "rubyd is stopped"
        1
      end
    end

    def bench
      options = {
        requests: 10_000,
        concurrency: 50,
        path: "/"
      }

      config = load_config
      options[:host] = config.host == "0.0.0.0" ? "127.0.0.1" : config.host
      options[:port] = config.port

      parser = OptionParser.new do |opts|
        opts.banner = "Usage: rubyd bench [options]"
        opts.on("-n", "--requests N", Integer, "Number of requests") { |v| options[:requests] = v }
        opts.on("-c", "--concurrency N", Integer, "Concurrent workers") { |v| options[:concurrency] = v }
        opts.on("--host HOST", String, "Target host") { |v| options[:host] = v }
        opts.on("-p", "--port PORT", Integer, "Target port") { |v| options[:port] = v }
        opts.on("--path PATH", String, "Target path") { |v| options[:path] = v }
      end

      parser.parse!(@argv)

      if options[:requests] <= 0 || options[:concurrency] <= 0
        @stderr.puts "requests and concurrency must be positive"
        return 1
      end

      Bench.new(**options, stdout: @stdout).run
      0
    rescue OptionParser::ParseError => e
      @stderr.puts e.message
      @stderr.puts "Use: rubyd bench -n 10000 -c 50"
      1
    end

    def serve
      config = load_config
      FileUtils.mkdir_p(File.dirname(config.pid_file))
      File.write(config.pid_file, Process.pid)

      at_exit do
        File.delete(config.pid_file) if File.exist?(config.pid_file)
      end

      Server.new(config).run
      0
    end

    def load_config
      path = ENV.fetch("RUBYD_CONFIG", "config.rb")
      Config.load(path)
    end

    def running_pid(pid_file)
      return nil unless File.exist?(pid_file)

      pid = Integer(File.read(pid_file).strip)
      return pid if process_alive?(pid)

      File.delete(pid_file)
      nil
    rescue ArgumentError
      nil
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def wait_for_start(pid_file, fallback_pid)
      50.times do
        return if File.exist?(pid_file) || process_alive?(fallback_pid)

        sleep 0.1
      end
    end

    def wait_for_stop(pid)
      100.times do
        return unless process_alive?(pid)

        sleep 0.1
      end
    end
  end
end
