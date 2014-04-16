require 'fileutils'

require 'duck/chroot_utils'
require 'duck/logging'
require 'duck/module_helper'

module Duck
  class Build
    include Logging
    include ChrootUtils
    include ModuleHelper

    def self.doc
      "Build the chroot"
    end

    FixesDir = 'fixes'
    FilesDir = 'files'
    KeysDir = 'keys'
    KeysRingsDir = 'keyrings'
    BootstrapStatus = '.bootstrap'
    DefaultSourceType = 'deb'
    DefaultComponents = ['main']
    DefaultSuite = 'squeeze'

    def initialize(options)
      @_roots = options[:_roots]
      @target = options[:target]
      @temp = options[:temp]
      @chroot_env = options[:env] || {}
      @packages = options[:packages] || []
      @fixes = options[:fixes] || []
      @sources = options[:sources]
      @transports = options[:transports]
      @bootstrap = validate_bootstrap options[:bootstrap]
      @keyring = validate_keyring options[:keyring]
      @files = validate_array [:from, :to], options[:files]
      @services = validate_array [:name], options[:services]
      @preferences = validate_array [:package, :pin, :priority], options[:preferences]

      if @bootstrap[:tarball]
        @bootstrap_tarball = File.join @temp, @bootstrap[:tarball]
      end

      @fixes_target = File.join @target, FixesDir
      @bootstrap_status = File.join @target, BootstrapStatus
    end

    def validate_keyring(opts)
      return nil unless opts
      raise "Missing required keyring option 'keyserver'" unless opts[:keyserver]
      opts[:keys] = [] unless opts[:keys]
      opts
    end

    def validate_bootstrap(opts)
      raise "Missing bootstrap options" unless opts
      opts[:suite] = DefaultSuite unless opts[:suite]
      return opts
    end

    def validate_item(keys, item)
      keys.each {|k| raise "Missing '#{k}' declaration" unless item[k]}
    end

    def validate_array(keys, items)
      items.each {|root, item| validate_item keys, item}
    end

    def copy_fixes
      FileUtils.mkdir_p @fixes_target unless File.directory? @fixes_target

      @fixes.each do |root, fix_name|
        source = File.join root, FixesDir, fix_name
        target = File.join @fixes_target, fix_name

        next unless File.file? source
        next if File.file? target and File.mtime(source) > File.mtime(target)

        log.debug "copying fix #{source} to #{target}"
        FileUtils.cp source, target
        FileUtils.chmod 0755, target
      end
    end

    def clear_fixes
      FileUtils.rm_rf @fixes_target
    end

    def run_fixes(stage)
      return unless File.directory? @fixes_target

      log.info "fixes: #{stage}"

      @fixes.each do |root, fix_name|
        log.debug "fix: #{fix_name} #{stage}"
        executable = File.join '/', FixesDir, fix_name
        exitcode = chroot [@target, executable, stage]
        raise "fix failed: #{fix_name} #{stage}" if exitcode != 0
      end
    end

    def check_keyring
      return unless @keyring

      missing_keys = []

      (@keyring[:keys] || []).each do |key|
        key_path = File.join KeysDir, "#{key}.gpg"
        next if File.file? key_path
        missing_keys << {:id => key, :path => key_path}
      end

      return if missing_keys.empty?

      log.error "Some required keys are missing from your keys directory"

      missing_keys.each do |key|
        log.error "Missing key: id: #{key[:id]}, path: #{key[:path]}"
      end

      raise StepError.new "Some required keys are missing from the keys directory"
    end

    def bootstrap_options
      opts = {
        :mirror => @bootstrap[:mirror],
        :extra => [
          "--variant=minbase",
        ] + (@bootstrap[:extra] || []),
      }

      unless @transports.empty?
        transports = @transports.map{|r, t| "apt-transport-#{t}"}
        log.debug "Installing extra transports: #{transports.join ' '}"
        opts[:extra] << '--include' << transports.join(',')
      end

      if @bootstrap[:keyringfile]
        key_path = File.join KeysRingsDir, "#{@bootstrap[:keyringfile]}"

        if File.file? key_path
          opts[:extra] << '--keyring' << key_path
        else
          log.error "Can't find key #{@bootstrap[:keyring]}"
        end
      end

      opts
    end

    def bootstrap_tarball
      return if File.file? @bootstrap_status
      return unless @bootstrap_tarball
      return if File.file? @bootstrap_tarball

      log.debug "Building tarball: #{@bootstrap_tarball}"

      opts = bootstrap_options
      opts[:extra] << '--make-tarball' << @bootstrap_tarball
      debootstrap @bootstrap[:suite], @target, opts
    end

    def bootstrap_install
      return if File.file? @bootstrap_status

      log.debug "Early stage bootstrap in #{@target}"

      opts = bootstrap_options

      if @bootstrap_tarball
        opts[:extra] << "--unpack-tarball" << @bootstrap_tarball
      end

      opts[:extra] << "--foreign"

      debootstrap @bootstrap[:suite], @target, opts
    end

    def bootstrap_configure
      return if File.file? @bootstrap_status

      log.debug "Late stage bootstrap in #{@target}"
      chroot [@target, '/debootstrap/debootstrap', '--second-stage']
    end

    def bootstrap_end
      FileUtils.touch @bootstrap_status
    end

    def read_file(source_dir, file)
      from = file[:from]
      to = file[:to]
      mode = file[:mode] || 0644
      mode = mode.to_i(8) if mode.is_a? String

      files_pattern = File.join source_dir, from
      source_files = Dir.glob files_pattern

      return nil if source_files.empty?

      target_to = File.join @target, to

      {:files => source_files, :to => target_to, :mode => mode}
    end

    def files_copy
      return if @files.empty?

      @_roots.each do |root|
        @files.each do |local_root, file|
          source_dir = File.join root, FilesDir
          file = read_file(source_dir, file)
          next if file.nil?

          FileUtils.mkdir_p file[:to]

          file[:files].each do |source|
            next unless File.file? source

            target = File.join file[:to], File.basename(source)

            # Skip if target already exists and is identical to source.
            next if File.file? target and FileUtils.compare_file source, target

            log.debug "Copying File: #{source} -> #{target}"

            FileUtils.cp source, target
            FileUtils.chmod file[:mode], target
          end
        end
      end
    end

    def packages_install
      return if @packages.empty?

      options = []
      options << 'DPkg::NoTriggers=true'
      options << 'PackageManager::Configure=no'
      options << 'DPkg::ConfigurePending=false'
      options << 'DPkg::TriggersPending=false'

      options = options.map{|option| ['-o', option]}.flatten

      packages = @packages.map{|r, p| p}

      log.debug "Installing Packages"
      packages_repr = packages.join ' '

      log.debug "Installing Packages: #{packages_repr}"
      in_apt_get *(options + ['install', '--'] + packages)
    end

    def packages_configure
      log.debug "Configuring Packages"
      in_dpkg '--configure', '-a', '--force-confdef', '--force-confold'
    end

    def sources_list(name, sources)
      sources_dir = File.join @target, 'etc', 'apt', 'sources.list.d'
      sources_list = File.join sources_dir, "#{name}.list"

      log.debug "Writing Sources #{sources_list}"

      File.open(sources_list, 'w', 0644) do |f|
        sources.each do |source|
          type = source[:type] || DefaultSourceType
          components = source[:components] || DefaultComponents
          suite = source[:suite]
          url = source[:url]

          raise "Missing 'url' in source" unless url
          raise "Missing 'suite' in source" unless suite

          f.write "#{type} #{url} #{suite} #{components.join ' '}\n"
        end
      end
    end

    def write_apt_preferences
      apt_preferences = File.join @target, 'etc', 'apt', 'preferences'

      return if File.file? apt_preferences

      log.debug "Writing Preferences #{apt_preferences}"

      File.open(apt_preferences, 'w', 0644) do |f|
        f.write "# generated by duck\n"

        @preferences.each do |root, pin|
          f.write "Package: #{pin[:package]}\n"
          f.write "Pin: #{pin[:pin]}\n"
          f.write "Pin-Priority: #{pin[:priority]}\n"
          f.write "\n"
        end
      end
    end

    def add_apt_keys
      log.debug "Adding APT keys"

      (@keyring[:keys] || []).each do |key|
        log.debug "Adding key'#{key}'"
        key_path = File.join KeysDir, "#{key}.gpg"

        File.open key_path, 'r' do |f|
          in_apt_key ['add', '-'], {:input_file => f}
        end
      end
    end

    def prepare_apt
      add_apt_keys if @keyring

      sources_list 'main', @sources.map{|r,s| s}
      in_apt_get 'update'
      write_apt_preferences
    end

    def add_policy_rcd
      policy_rcd = File.join @target, 'usr', 'sbin', 'policy-rc.d'

      if File.file? policy_rcd
        log.debug "Policy OK: #{policy_rcd}"
        return
      end

      log.debug "Writing Folicy: #{policy_rcd}"

      File.open(policy_rcd, 'w', 0755) do |f|
        f.write("#/bin/sh\n")
        f.write("exit 101\n")
      end
    end

    # Remove the policy-rc.d from within the chroot.
    def remove_policy_rcd
      policy_rcd = File.join @target, 'usr', 'sbin', 'policy-rc.d'
      log.debug "Removing Policy: #{policy_rcd}"
      FileUtils.rm_f policy_rcd
    end

    # Completely disable the specified runlevel.
    def disable_runlevel(runlevel)
      runlevel_dir = File.join @target, 'etc', "rc#{runlevel}.d"
      raise "No such runlevel: #{runlevel}" unless File.directory? runlevel_dir

      Find.find(runlevel_dir) do |path|
        name = File.basename path

        if name =~ /^S..(.+)$/
          service = $1
          log.debug "Disabling Service '#{service}'"
          in_update_rcd '-f', service, 'remove'
        end
      end
    end

    # Make sure that the specified boot service (and only those specified) are
    # enabled.
    def configure_boot_services
      disable_runlevel '2'
      disable_runlevel 'S'

      @services.each do |root, service|
        args = [service[:name]]
        args += ['start'] + service[:start].split(' ') if service[:start]
        args += ['stop'] + service[:stop].split(' ') if service[:stop]
        in_update_rcd '-f', *args
      end
    end

    # define all the different steps involved.
    step :check_keyring, :disable_hooks => true
    step :bootstrap_tarball, :disable_hooks => true
    step :bootstrap_install, :disable_hooks => true
    step :copy_fixes, :disable_hooks => true
    step :bootstrap_configure
    step :bootstrap_end
    step :add_policy_rcd
    step :prepare_apt
    step :packages_install
    step :packages_configure
    step :files_copy
    step :configure_boot_services
    step :remove_policy_rcd

    def pre_hook(name)
        run_fixes "pre-#{name}"
    end

    def post_hook(name)
        run_fixes "post-#{name}"
    end

    def final_hook
      run_fixes "final"
      clear_fixes
    end
  end
end
