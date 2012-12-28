require 'duck/spawn_utils'

module Duck
  class Qemu
    include SpawnUtils
    include Logging

    def initialize(options)
      @target = options[:target]
      @kernel = options[:kernel]
      @initrd = options[:initrd]
      raise "No kernel specified" unless @kernel
      raise "Specified kernel does not exist: #{@kernel}" unless File.file? @kernel
      raise "No initrd specified" unless @initrd
      raise "Specified initrd does not exist: #{@initrd}" unless File.file? @initrd
    end

    def execute
      opts = [
        '-serial', 'stdio', '-m', '512',
        '-append', 'console=ttyS0 duck/mode=testing',
      ]

      args = [
        '-kernel', @kernel,
        '-initrd', @initrd,
      ] + opts

      log.info "Executing QEMU on #{@initrd}"
      local_qemu args
    end
  end
end
