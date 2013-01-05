require 'duck/spawn_utils'

module Duck
  class Qemu
    include SpawnUtils
    include Logging

    def initialize(options)
      @target = options[:target]
      @kernel = options[:kernel]
      @initrd = options[:initrd]
      @append = options[:append]
      raise "No kernel specified" unless @kernel
      raise "Specified kernel does not exist: #{@kernel}" unless File.file? @kernel
      raise "No initrd specified" unless @initrd
      raise "Specified initrd does not exist: #{@initrd}" unless File.file? @initrd
    end

    def execute
      append = 'console=ttyS0 duck/mode=testing'
      append = "#{append} #{@append}" if @append

      opts = ['-serial', 'stdio', '-m', '1024', '-append', append]

      args = [
        '-kernel', @kernel,
        '-initrd', @initrd,
      ] + opts

      log.info "Executing QEMU on #{@initrd}"
      qemu *args
    end
  end
end
