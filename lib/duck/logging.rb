require 'logger'

module Logging
  def log
    @log ||= Logging.logger_for(self.class.name)
  end

  @loggers = {}
  @log_level = Logger::INFO

  class << self
    def logger_for(name)
      @loggers[name] ||= setup_logger_for(name)
    end

    def setup_logger_for(name)
      log = Logger.new(STDOUT)
      log.progname = name
      log.level = @log_level
      log
    end

    def set_level(level)
      @loggers.each do |key, value|
        value.level = level
      end

      @log_level = level
    end
  end
end
