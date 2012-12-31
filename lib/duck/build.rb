require 'fileutils'

require 'duck/chroot_utils'
require 'duck/logging'

module Duck
  class StepError < Exception
  end

  class Build
    FIXES = 'fixes'
    DEFAULT_TYPE = 'deb'
    DEFAULT_COMPONENTS = ['main']
    DEFAULT_SUITE = 'squeeze'

    # define all the different steps involved.
    STEPS = [
      [false, :check_keyring],
      [false, :bootstrap_tarball],
      [false, :bootstrap_install],
      [true, :bootstrap_configure],
      [true, :bootstrap_end],
      [true, :add_policy_rcd],
      [true, :prepare_apt],
      [true, :packages_install],
      [true, :packages_configure],
      [true, :files_copy],
      [true, :configure_boot_services],
      [true, :remove_policy_rcd],
    ]

    include Logging
    include ChrootUtils

    def initialize(options)
      @target = options[:target]
      @temp = options[:temp]
      @keys_dir = options[:keys_dir]
      @chroot_env = options[:env] || {}
      @packages = options[:packages] || []
      @gpg_homedir = options[:gpg_homedir]
      @bootstrap_status = options[:bootstrap_status]
      @fixes = options[:fixes]
      @files_dir = options[:files_dir]
      @build_sources = options[:build_sources]
      @main_sources = options[:main_sources]
      @transports = options[:transports]
      @bootstrap = validate_bootstrap options[:bootstrap]
      @keyring = validate_keyring options[:keyring]
      @files = validate_array [:from, :to], options[:files]
      @services = validate_array [:name], options[:services]
      @preferences = validate_array [:package, :pin, :priority], options[:preferences]
      @_roots = options[:_roots]
      @bootstrap_tarball = File.join @temp, @bootstrap[:tarball]
      @target_fixes = File.join @target, FIXES
    end

    def validate_keyring(opts)
      return nil unless opts
      raise "Missing required keyring option 'keyserver'" unless opts[:keyserver]
      opts[:keys] = [] unless opts[:keys]
      opts
    end

    def validate_bootstrap(opts)
      raise "Missing bootstrap options" unless opts
      opts[:suite] = default_suite unless opts[:suite]
      return opts
    end

    def validate_item(keys, item)
      keys.each {|k| raise "Missing '#{k}' declaration" unless item[k]}
    end

    def validate_array(keys, items)
      items.each {|item| validate_item keys, item}
    end

    def check_keyring
      missing_keys = []

      @keyring[:keys].each do |key|
        key_path = File.join(@keys_dir, "#{key}.gpg")
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

    def bootstrap_tarball
      return if File.file? @bootstrap_status
      return unless @bootstrap[:tarball]
      return if File.file? @bootstrap_tarball

      log.debug "Building tarball: #{@bootstrap_tarball}"

      opts = {
        :mirror => @bootstrap[:mirror],
        :extra => ["--make-tarball=#{@bootstrap_tarball}"],
      }

      debootstrap @bootstrap[:suite], @target, opts
    end

    def bootstrap_install
      return if File.file? @bootstrap_status

      log.debug "Early stage bootstrap in #{@target}"

      opts = {
        :mirror => @bootstrap[:mirror],
        :extra => ["--foreign"],
      }

      if @bootstrap[:tarball]
        opts[:extra] << "--unpack-tarball=#{@bootstrap_tarball}"
      end

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

    def fixes(stage)
      log.info "fixes: #{stage}"

      FileUtils.mkdir_p @target_fixes unless File.directory? @target_fixes

      @_roots.each do |root|
        @fixes.each do |fix_name|
          source = File.join root, FIXES, fix_name
          target = File.join @target_fixes, fix_name
          executable = File.join '/', FIXES, fix_name

          next unless File.file? source

          unless File.file? target and File.mtime(source) <= File.mtime(target)
            log.debug "copying #{source} -> #{target}"
            FileUtils.cp source, target
            FileUtils.chmod 0755, target
          end

          log.debug "fix: #{fix_name} #{stage}"
          exitcode = chroot [@target, executable, stage]
          raise "fix failed: #{fix_name} #{stage}" if exitcode != 0
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

    def files_copy
      return if @files.empty?

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

      log.debug "Installing Packages"
      packages_repr = @packages.join ' '

      log.debug "Installing Packages: #{packages_repr}"
      in_apt_get *(options + ['install', '--'] + @packages)
    end

    def packages_configure
      log.debug "Configuring Packages"
      in_dpkg '--configure', '-a'
    end

    def sources_list(sources, name)
      sources_dir = File.join @target, 'etc', 'apt', 'sources.list.d'
      sources_list = File.join sources_dir, "#{name}.list"

      log.debug "Writing Sources #{sources_list}"

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

      log.debug "Writing Preferences #{apt_preferences}"

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

    def add_apt_keys
      log.debug "Adding APT keys"

      @keyring[:keys].each do |key|
        log.debug "Adding key'#{key}'"
        key_path = File.join @keys_dir, "#{key}.gpg"

        File.open(key_path, 'r') do |f|
          in_apt_key ['add', '-'], {:input_file => f}
        end
      end
    end

    def prepare_apt
      raise "Required section 'build_sources' missing" unless @build_sources

      add_apt_keys

      sources_list @build_sources, 'build'

      unless @transports.empty?
        transports = @transports.map{|t| "apt-transport-#{t}"}
        log.debug "Installing extra transports: #{transports.join ' '}"
        in_apt_get 'update'
        in_apt_get 'install', *transports
      end

      sources_list @main_sources, 'main' if @main_sources
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

    def remove_policy_rcd
      policy_rcd = File.join @target, 'usr', 'sbin', 'policy-rc.d'
      log.debug "Removing Policy: #{policy_rcd}"
      FileUtils.rm_f policy_rcd
    end

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

    def configure_boot_services
      disable_runlevel '2'
      disable_runlevel 'S'

      @services.each do |service|
        args = [service[:name]]
        args += ['start'] + service[:start].split(' ') if service[:start]
        args += ['stop'] + service[:stop].split(' ') if service[:stop]
        in_update_rcd '-f', *args
      end
    end

    def execute
      STEPS.each do |run_fixes, step_method|
        name = step_method.to_s.gsub '_', '-'

        log.info "#{name}: running"
        fixes "pre-#{name}" if run_fixes

        begin
          self.method(step_method).call
        rescue StepError
          log.error "#{name}: #{$!}"
          return
        end

        log.info "#{name}: done"
        fixes "post-#{name}" if run_fixes
      end

      # run fixes for finalizing the setup.
      fixes "final"
      return 0
    end
  end
end
