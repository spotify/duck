require 'fileutils'

require 'duck/chroot_utils'
require 'duck/logging'

module Duck
  class Build
    DEFAULT_TYPE = 'deb'
    DEFAULT_COMPONENTS = ['main']

    include Logging
    include ChrootUtils

    def initialize(options)
      @env = options[:env] || {}
      @packages = options[:packages] || []
      @debootstrap = options[:debootstrap] || {}
      @debootstrap_tarball = options[:debootstrap_tarball]
      @target = options[:target]
      @bootstrap_status = options[:bootstrap_status]
      @fixes = options[:fixes]
      @fixes_dir = options[:fixes_dir]
      @files_dir = options[:files_dir]
      @target_fixes = options[:target_fixes]
      @build_sources = options[:build_sources]
      @main_sources = options[:main_sources]
      @transports = options[:transports]
      @files = validate_array [:from, :to], options[:files]
      @services = validate_array [:name], options[:services]
      @preferences = validate_array [:package, :pin, :priority], options[:preferences]
      @debootstrap[:tarball] = @debootstrap_tarball if @debootstrap_tarball
      @_roots = options[:_roots]
    end

    def validate_item(keys, item)
      keys.each {|k| raise "Missing '#{k}' declaration" unless item[k]}
    end

    def validate_array(keys, items)
      items.each {|item| validate_item keys, item}
    end

    def early_bootstrap
      args = @debootstrap.clone

      if @debootstrap_tarball
        unless File.file? @debootstrap_tarball
          log.info "Building tarball: #{@debootstrap_tarball}"
          local_debootstrap @target, "--make-tarball=#{@debootstrap_tarball}", @debootstrap
        end
      end

      log.info "Early stage debootstrap in #{@target}"
      local_debootstrap @target, '--foreign', @debootstrap
    end

    def late_bootstrap
      log.info "Late stage debootstrap in #{@target}"
      local_chroot [@target, '/debootstrap/debootstrap', '--second-stage']
    end

    def all_bootstrap
      if File.file? @bootstrap_status
        log.info "Already Bootstrapped: #{@bootstrap_status}"
        return
      end

      log.info "Bootstrapping: #{@target}"
      early_bootstrap
      run_fixes "pre-bootstrap"
      late_bootstrap
      run_fixes "post-bootstrap"

      FileUtils.touch @bootstrap_status
    end

    def run_fixes(stage)
      FileUtils.mkdir_p @target_fixes unless File.directory? @target_fixes

      @_roots.each do |root|
        @fixes.each do |fix_name|
          fix_source = File.join root, @fixes_dir, fix_name
          next unless File.file? fix_source

          fix_target = File.join @target_fixes, fix_name
          fix_run = File.join '/', @fixes_dir, fix_name

          unless File.file? fix_target
            log.info "Copying fix #{fix_source} -> #{fix_target}"
            FileUtils.cp fix_source, fix_target
            FileUtils.chmod 0755, fix_target
          end

          log.info "Running fix '#{fix_name}': #{fix_run} #{stage}"
          local_chroot [@target, fix_run, stage]
        end
      end
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

    def install_manifest
      return if @files.empty?

      log.info "Installing Files"

      @_roots.each do |root|
        @files.each do |file|
          source_dir = File.join root, @files_dir
          file = read_file(source_dir, file)
          next if file.nil?

          FileUtils.mkdir_p file[:to]

          file[:files].each do |source|
            next unless File.file? source
            target = File.join file[:to], File.basename(source)
            # Skip if target already exists and is identical to source.
            next if File.file? target and FileUtils.compare_file source, target
            log.info "Copying File: #{source} -> #{target}"
            FileUtils.cp source, target
            FileUtils.chmod file[:mode], target
          end
        end
      end

      log.info "Done Installing Files"
    end

    def install_packages
      return if @packages.empty?

      options = []
      options << 'DPkg::NoTriggers=true'
      options << 'PackageManager::Configure=no'
      options << 'DPkg::ConfigurePending=false'
      options << 'DPkg::TriggersPending=false'

      options = options.map{|option| ['-o', option]}.flatten

      log.info "Installing Packages"
      packages_repr = @packages.join ' '

      log.info "Installing Packages: #{packages_repr}"
      apt_get *(options + ['install', '--'] + @packages)

      log.info "Configuring Packages"
      run_fixes "pre-configure"
      dpkg '--configure', '-a'
      run_fixes "post-configure"
    end

    def sources_list(sources, name)
      sources_dir = File.join @target, 'etc', 'apt', 'sources.list.d'
      sources_list = File.join sources_dir, "#{name}.list"

      log.info "Writing Sources #{sources_list}"

      File.open(sources_list, 'w', 0644) do |f|
        sources.each do |source|
          type = source[:type] || DEFAULT_TYPE
          components = source[:components] || DEFAULT_COMPONENTS
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

      log.info "Writing Preferences #{apt_preferences}"

      File.open(apt_preferences, 'w', 0644) do |f|
        f.write "# generated by duck\n"

        @preferences.each do |pin|
          f.write "Package: #{pin[:package]}\n"
          f.write "Pin: #{pin[:pin]}\n"
          f.write "Pin-Priority: #{pin[:priority]}\n"
          f.write "\n"
        end
      end
    end

    def prepare_apt
      raise "Required section 'build_sources' missing" unless @build_sources
      sources_list @build_sources, 'build'

      unless @transports.empty?
        transports = @transports.map{|t| "apt-transport-#{t}"}
        log.info "Installing extra transports: #{transports.join ' '}"
        apt_get 'update'
        apt_get 'install', *transports
      end

      sources_list @main_sources, 'main' if @main_sources
      apt_get 'update'
      write_apt_preferences
    end

    def setup_policy_rcd
      policy_rcd = File.join @target, 'usr', 'sbin', 'policy-rc.d'

      if File.file? policy_rcd
        log.info "Policy OK: #{policy_rcd}"
        return
      end

      log.info "Writing Folicy: #{policy_rcd}"
      File.open(policy_rcd, 'w', 0755) do |f|
        f.write("#/bin/sh\n")
        f.write("exit 101\n")
      end
    end

    def disable_runlevel(runlevel)
      runlevel_dir = File.join @target, 'etc', "rc#{runlevel}.d"
      raise "No such runlevel: #{runlevel}" unless File.directory? runlevel_dir

      Find.find(runlevel_dir) do |path|
        name = File.basename path

        if name =~ /^S..(.+)$/
          service = $1
          log.info "Disabling Service '#{service}'"
          update_rcd '-f', service, 'remove'
        end
      end
    end

    def configure_boot_services
      disable_runlevel '2'
      disable_runlevel 'S'

      @services.each do |service|
        args = [service[:name]]
        args += ['start'] + service[:start].split(' ') if service[:start]
        args += ['stop'] + service[:stop].split(' ') if service[:stop]
        update_rcd '-f', *args
      end
    end

    def execute
      all_bootstrap
      prepare_apt
      setup_policy_rcd
      install_packages
      install_manifest
      configure_boot_services
      return 0
    end
  end
end
