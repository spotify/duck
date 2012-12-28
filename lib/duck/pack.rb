require 'duck/chroot_utils'
require 'duck/logging'

module Duck
  class Pack
    include ChrootUtils

    def initialize(options)
      @target = options[:target]
      @env = options[:env]
      @initrd = options[:initrd]
      @minimize = options[:minimize]
    end

    def minimize_target
      log.info "Minimizing Target"
      apt_get "clean"
      shell "rm -rf /var/lib/{apt,dpkg} /usr/share/{doc,man} /var/cache"
    end

    def execute
      minimize_target if @minimize

      Dir.chdir @target
      log.info "Packing #{@target} into #{@initrd}"
      local_shell "find . | cpio -o -H newc | gzip > #{@initrd}"
      log.info "Done building initramfs image: #{@initrd}"
    end
  end
end
