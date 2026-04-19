# frozen_string_literal: true

require "time"
require "fileutils"
require "thread"

module Rubyd
  class Logger
    LEVELS = {
      debug: 0,
      info: 1,
      warn: 2,
      error: 3
    }.freeze

    def initialize(access_log_path:, error_log_path:, level: :info, rotate_size: 10 * 1024 * 1024, rotate_keep: 5)
      @level = LEVELS.fetch(level.to_sym, LEVELS[:info])
      @mutex = Mutex.new
      @rotate_size = rotate_size
      @rotate_keep = rotate_keep
      @access_log_path = access_log_path
      @error_log_path = error_log_path

      FileUtils.mkdir_p(File.dirname(access_log_path))
      FileUtils.mkdir_p(File.dirname(error_log_path))

      @access_log = File.open(access_log_path, "a")
      @error_log = File.open(error_log_path, "a")
      @access_log.sync = true
      @error_log.sync = true
    end

    def close
      @mutex.synchronize do
        @access_log&.close
        @error_log&.close
      end
    end

    def access(message)
      write(@access_log, "ACCESS", message)
    end

    def debug(message)
      log(:debug, message)
    end

    def info(message)
      log(:info, message)
    end

    def warn(message)
      log(:warn, message)
    end

    def error(message)
      log(:error, message)
    end

    private

    def log(level, message)
      return if LEVELS[level] < @level

      write(@error_log, level.to_s.upcase, message)
    end

    def write(io, tag, message)
      @mutex.synchronize do
        rotate_if_needed(io)
        io.puts("[#{Time.now.iso8601}] [#{tag}] #{message}")
      end
    end

    def rotate_if_needed(io)
      return unless io.size >= @rotate_size

      if io == @access_log
        rotate_file!(@access_log_path)
        @access_log&.close
        @access_log = File.open(@access_log_path, "a")
        @access_log.sync = true
      else
        rotate_file!(@error_log_path)
        @error_log&.close
        @error_log = File.open(@error_log_path, "a")
        @error_log.sync = true
      end
    end

    def rotate_file!(path)
      (@rotate_keep - 1).downto(1) do |index|
        older = "#{path}.#{index}"
        newer = "#{path}.#{index + 1}"
        File.rename(older, newer) if File.exist?(older)
      end

      first = "#{path}.1"
      File.rename(path, first) if File.exist?(path)
      stale = "#{path}.#{@rotate_keep + 1}"
      File.delete(stale) if File.exist?(stale)
    rescue StandardError
      nil
    end
  end
end
