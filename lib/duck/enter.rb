require 'duck/chroot_utils'
require 'duck/logging'

module Duck
  class Enter
    include ChrootUtils
    include Logging

    def self.doc
      "Enter the build chroot"
    end

    def initialize(options)
      @target = options[:target]
      @shell = options[:shell]
      @chroot_env = options[:env] || {}
    end

    def execute
      log.info "Entering #{@target}"
      chroot [@target, @shell], :env => @chroot_env
    end
  end
end
