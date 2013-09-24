require 'duck/chroot_utils'
require 'duck/logging'

module Duck
  class Pack
    include ChrootUtils
    include Logging

    def self.doc
      "Pack the chroot into an archive"
    end

    def initialize(options)
      @target = options[:target]
      @original_target = @target
      @target_min = "#{@target}.min"
      @chroot_env = options[:env]
      @initrd = options[:initrd]
      @no_minimize = options[:no_minimize]
      @keep_minimized = options[:keep_minimized]
      @strip = options[:strip]
    end

    def minimize_target
      log.info "Minimizing Target"
      spawn ['rm', '-rf', @target_min] if File.directory? @target_min
      spawn ['cp', '-a', @target, @target_min]

      @target = @target_min

      in_apt_get "clean"
      in_shell "rm -rf /boot /usr/share/doc /var/cache/{apt,debconf}/*"
      in_shell "find /var/lib/apt/lists/ -type f ! -name lock -delete"
    end

    def execute
      minimize_target unless @no_minimize

      Dir.chdir @target
      if @strip
        log.info "Stripping contents of #{@target}"
        shell "find . -type f -exec strip --strip-unneeded -R .comment -R .note '{}' + >/dev/null 2>&1 || true"
      end
      log.info "Packing #{@target} into #{@initrd}"
      shell "find . | cpio -o -H newc | lzma -9 > #{@initrd}"

      spawn ['rm', '-r', '-f', @target] unless @keep_minimized

      log.info "Done building initramfs image: #{@initrd}"
    end
  end
end
