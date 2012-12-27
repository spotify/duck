#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'fileutils'
require 'logger'
require 'yaml'
require 'find'

DEFAULT_SUITE = 'squeeze'

# environment to prevent tasks from being interactive.

DEFAULT_SHELL = '/bin/bash'
FILES_DIR = 'files'
FIXES_DIR = 'fixes'
CONFIG_NAME = 'duck.yaml'
CONFIG_ARRAYS = [:files, :packages, :transports, :preferences, :fixes, :services]

# Alternatives for shared configuration.
SHARED_CONFIG = [
  "/usr/local/share/duck/#{CONFIG_NAME}",
  "/usr/share/duck/#{CONFIG_NAME}",
]

$log = Logger.new STDOUT
$log.level = Logger::INFO

module SpawnUtils
  SH = 'sh'
  DEBOOTSTRAP = 'debootstrap'
  QEMU = 'qemu-system-x86_64'

  def spawn(args, params={})
    env = params[:env] || {}

    repr = args.join " "

    child_pid = fork do
      ENV.update env
      exec *args
      exit 255
    end

    Process.wait child_pid
    exit_status = $?.exitstatus

    if exit_status != 0
      raise "#{repr}: Subprocess returned non-zero exit status: #{exit_status}"
    end

    return exit_status
  end

  def local_shell(command)
    spawn [SH, '-c', command]
  end

  def local_debootstrap(target, step, options={})
    suite = options[:suite] || DEFAULT_SUITE
    debootstrap_args = Array.new(options[:extra] || [])

    if options[:tarball] and File.file? options[:tarball]
      debootstrap_args << "--unpack-tarball=#{options[:tarball]}"
    end

    debootstrap_args << step << suite << target
    debootstrap_args << options[:mirror] if options.include? :mirror
    spawn [DEBOOTSTRAP] + debootstrap_args
  end

  def local_qemu(args)
    spawn [QEMU] + args
  end
end

module ChrootUtils
  include SpawnUtils

  CHROOT = 'chroot'
  APT_GET = 'apt-get'
  DPKG = 'dpkg'
  UPDATE_RCD = 'update-rc.d'
  SH = 'sh'

  CHROOT_ENV = {
    'DEBIAN_FRONTEND' => 'noninteractive',
    'DEBCONF_NONINTERACTIVE_SEEN' => 'true',
    'LC_ALL' => 'C',
    'LANGUAGE' => 'C',
    'LANG' => 'C',
  }

  def local_chroot(args, options={})
    spawn [CHROOT] + args, options
  end

  # for doing automated tasks inside of the chroot.
  def auto_chroot(args)
    $log.info "chroot: #{args.join ' '}"
    env = Hash.new(@env || {}).merge(CHROOT_ENV)
    local_chroot [@target] + args, :env => env
  end

  def apt_get(*args)
    auto_chroot [APT_GET, '-y', '--force-yes'] + args
  end

  def dpkg(*args)
    auto_chroot [DPKG] + args
  end

  def shell(command)
    auto_chroot [SH, '-c', command]
  end

  def update_rcd(*args)
    auto_chroot [UPDATE_RCD] + args
  end
end

class Build
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
        $log.info "Building tarball: #{@debootstrap_tarball}"
        local_debootstrap @target, "--make-tarball=#{@debootstrap_tarball}", @debootstrap
      end
    end

    $log.info "Early stage debootstrap in #{@target}"
    local_debootstrap @target, '--foreign', @debootstrap
  end

  def late_bootstrap
    $log.info "Late stage debootstrap in #{@target}"
    local_chroot [@target, '/debootstrap/debootstrap', '--second-stage']
  end

  def all_bootstrap
    if File.file? @bootstrap_status
      $log.info "Already Bootstrapped: #{@bootstrap_status}"
      return
    end

    $log.info "Bootstrapping: #{@target}"
    early_bootstrap
    run_fixes "pre-bootstrap"
    late_bootstrap
    run_fixes "post-bootstrap"

    FileUtils.touch @bootstrap_status
  end

  def run_fixes(stage)
    @_roots.each do |root|
      @fixes.each do |fix_name|
        fix_source = File.join root, @fixes_dir, fix_name
        next unless File.file? fix_source

        fix_target = File.join @target_fixes, fix_name
        fix_run = File.join '/', @fixes_dir, fix_name

        unless File.file? fix_target
          $log.info "Copying fix #{fix_source} -> #{fix_target}"
          FileUtils.cp fix_source, fix_target
          FileUtils.chmod 0755, fix_target
        end

        $log.info "Running fix '#{fix_name}': #{fix_run} #{stage}"
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

    return {:files => source_files, :to => target_to, :mode => mode}
  end

  def install_manifest
    return if @files.empty?

    $log.info "Installing Files"

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
          $log.info "Copying File: #{source} -> #{target}"
          FileUtils.cp source, target
          FileUtils.chmod file[:mode], target
        end
      end
    end

    $log.info "Done Installing Files"
  end

  def install_packages
    return if @packages.empty?

    options = []
    options << 'DPkg::NoTriggers=true'
    options << 'PackageManager::Configure=no'
    options << 'DPkg::ConfigurePending=false'
    options << 'DPkg::TriggersPending=false'

    options = options.map{|option| ['-o', option]}.flatten

    $log.info "Installing Packages"
    packages_repr = @packages.join ' '

    $log.info "Installing Packages: #{packages_repr}"
    apt_get *(options + ['install', '--'] + @packages)

    $log.info "Configuring Packages"
    run_fixes "pre-configure"
    dpkg '--configure', '-a'
    run_fixes "post-configure"
  end

  def sources_list(sources, name)
    sources_dir = File.join @target, 'etc', 'apt', 'sources.list.d'
    sources_list = File.join sources_dir, "#{name}.list"

    $log.info "Writing Sources #{sources_list}"

    File.open(sources_list, 'w', 0644) do |f|
      sources.each do |source|
        type = source[:type] || 'deb'
        components = source[:components] || ['main']
        url = source[:url]
        suite = source[:suite]

        raise "Missing 'url' in source" unless url
        raise "Missing 'suite' in source" unless suite

        f.write "#{type} #{url} #{suite} #{components.join ' '}\n"
      end
    end
  end

  def write_apt_preferences
    apt_preferences = File.join @target, 'etc', 'apt', 'preferences'

    return if File.file? apt_preferences

    $log.info "Writing Preferences #{apt_preferences}"

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
      $log.info "Installing extra transports: #{transports.join ' '}"
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
      $log.info "Policy OK: #{policy_rcd}"
      return
    end

    $log.info "Writing Folicy: #{policy_rcd}"
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
        $log.info "Disabling Service '#{service}'"
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

class Enter
  include ChrootUtils

  def initialize(options)
    @target = options[:target]
    @shell = options[:shell]
    @env = options[:env] || {}
  end

  def execute
    local_chroot [@target, @shell], :env => @env
  end
end

class Pack
  include ChrootUtils

  def initialize(options)
    @target = options[:target]
    @env = options[:env]
    @initrd = options[:initrd]
    @minimize = options[:minimize]
  end

  def minimize_target
    $log.info "Minimizing Target"
    apt_get "clean"
    shell "rm -rf /var/lib/{apt,dpkg} /usr/share/{doc,man} /var/cache"
  end

  def execute
    minimize_target if @minimize

    Dir.chdir @target
    $log.info "Packing #{@target} into #{@initrd}"
    local_shell "find . | cpio -o -H newc | gzip > #{@initrd}"
    $log.info "Done building initramfs image: #{@initrd}"
  end
end

class Qemu
  include SpawnUtils

  def initialize(options)
    @target = options[:target]
    @kernel = options[:kernel]
    @initrd = options[:initrd]
    raise "No kernel specified" unless @kernel
    raise "Specified kernel does not exist: #{@kernel}" unless File.file? @kernel
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

    $log.info "Executing QEMU on #{@initrd}"
    local_qemu args
  end
end

def parse_options(args)
  o = Hash.new

  working_directory = Dir.pwd
  working_directory_config = File.join(working_directory, CONFIG_NAME)

  o[:target] = File.join working_directory, 'tmp', 'initrd'
  o[:initrd] = File.join working_directory, 'tmp', 'initrd.gz'
  o[:kernel] = File.join working_directory, 'vmlinuz'
  o[:minimize] = false
  o[:files] = []
  o[:services] = []
  o[:packages] = []
  o[:transports] = []
  o[:fixes] = []
  o[:preferences] = []
  o[:shell] = DEFAULT_SHELL
  o[:fixes_dir] = FIXES_DIR
  o[:files_dir] = FILES_DIR
  o[:debootstrap_tarball] = File.join working_directory, 'tmp', 'debootstrap.tar'
  o[:_configs] = []

  action_names = [:build, :pack]

  opts = OptionParser.new do |opts|
    opts.banner = 'Usage: duck [action] [options]'

    opts.on('-t <dir>', '--target <dir>',
            'Build in the specified target directory') do |dir|
      o[:target] = dir
    end

    opts.on('--minimize',
            'Minimize the installation right before packing') do |dir|
      o[:minimize] = true
    end

    opts.on('-o <file>', '--output <file>',
            'Output the resulting initrd in the specified path') do |path|
      o[:initrd] = path
    end

    opts.on('-k <kernel>', '--kernel <kernel>',
            'Specify kernel to use when running qemu') do |path|
      o[:kernel] = path
    end

    opts.on('-c <path>', '--config <path>',
            'Use the specified configuration path') do |path|
      o[:_configs] << path
    end

    opts.on('-s <shell>', '--shell <shell>',
            'Set the shell to use when chrooting') do |shell|
      o[:shell] = shell
    end

    opts.on('-h', '--help', 'Show this message') do
      puts opts
      return nil
    end
  end

  args = opts.parse! args

  unless args.empty?
    action_names = args.map{|a| a.to_sym}
  end

  # Used when checking for direct call to binary.
  binary_root = File.dirname File.dirname(File.expand_path($0))
  binary_config = File.join binary_root, CONFIG_NAME

  o[:bootstrap_status] = File.join o[:target], '.debootstrap'

  # add default configuration if none is specified.
  if o[:_configs].empty?
    o[:_configs] << working_directory_config
  end

  # If binary_config exists then we are running the command from the
  # development directory, include configuration from here instead of shared
  # paths.
  if File.file? binary_config
    o[:_configs] = [binary_config] + o[:_configs]
  else
    o[:_configs] = SHARED_CONFIG + o[:_configs]
  end

  o[:_configs].uniq!
  o[:_configs].reject!{|i| not File.file? i}
  return action_names, o
end

def deep_symbolize(o)
  return o.map{|i| deep_symbolize(i)} if o.is_a? Array
  return o unless o.is_a? Hash
  c = o.clone
  c.keys.each {|k| c[k.to_sym] = deep_symbolize(c.delete(k))}
  return c
end

def prepare_options(o)
  unless File.directory? o[:target]
    $log.info "Creating target directory: #{o[:target]}"
    FileUtils.mkdir_p o[:target]
  end

  raise "No configuration found" if o[:_configs].empty?

  o[:target_fixes] = File.join o[:target], o[:fixes_dir]

  FileUtils.mkdir_p o[:target] unless File.directory? o[:target]
  FileUtils.mkdir_p o[:target_fixes] unless File.directory? o[:target_fixes]

  o[:_roots] = o[:_configs].map{|c| File.dirname c}

  o[:_configs].each do |config_path|
    $log.info "Loading configuration from #{config_path}"
    config = deep_symbolize YAML.load_file(config_path)
    # Special keys treated as accumulated arrays over all configurations.
    CONFIG_ARRAYS.each{|n| o[n] += config.delete(n) || []}
    # Merge (overwrite) the rest.
    o.merge! config
  end
end

ACTTIONS = {
  :build => Build,
  :enter => Enter,
  :pack => Pack,
  :qemu => Qemu,
}

def main(args)
  action_names, o = parse_options args
  return 0 if o.nil?
  prepare_options o

  action_names.each do |action_name|
    action_class = ACTTIONS[action_name]

    if action_class.nil?
      $log.error "No such action: #{action_name}"
      return 1
    end

    action_instance = action_class.new o
    action_instance.execute
  end

  return 0
end

exit main(ARGV) if __FILE__ == $0
