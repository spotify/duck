require 'duck/chroot_utils'
require 'duck/logging'

module Duck
  class Enter
    include ChrootUtils
    include Logging

    def initialize(options)
      @target = options[:target]
      @shell = options[:shell]
      @env = options[:env] || {}
    end

    def execute
      log.info "Entering #{@target}"
      local_chroot [@target, @shell], :env => @env
    end
  end
end
