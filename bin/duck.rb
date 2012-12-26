#!/usr/bin/env ruby

require 'optparse'
require 'ostruct'
require 'fileutils'
require 'logger'
require 'yaml'

DEFAULT_SUITE = 'squeeze'

# environment to prevent tasks from being interactive.
CHROOT_ENV = {
  'DEBIAN_FRONTEND' => 'noninteractive',
  'DEBCONF_NONINTERACTIVE_SEEN' => 'true',
  'LC_ALL' => 'C',
  'LANGUAGE' => 'C',
  'LANG' => 'C',
}

DEFAULT_SHELL = '/bin/bash'
FILES_DIR = 'files'
FIXES_DIR = 'fixes'
CONFIG_NAME = 'duck.yaml'
CONFIG_ARRAYS = [:files, :packages, :transports, :pinning, :fixes]

# Alternatives for shared configuration.
SHARED_CONFIG = [
  "/usr/local/share/duck/#{CONFIG_NAME}",
  "/usr/share/duck/#{CONFIG_NAME}",
]

=begin
  Class to encapsulate running of external commands.
=end
class Command
  def initialize(name, params={})
    @name = name
    @out = params[:out] || $stdout
  end

  def call(args, params={})
    env = params[:env] || {}

    args = [@name] + args

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
end

$chroot = Command.new 'chroot'
$debootstrap = Command.new 'debootstrap'

$log = Logger.new STDOUT
$log.level = Logger::INFO

module Build
  class << self
    def debootstrap(step, target, args={})
      suite = args[:suite] || DEFAULT_SUITE
      debootstrap_args = Array.new(args[:extra] || [])
      debootstrap_args << step << suite << target
      debootstrap_args << args[:mirror] if args.include? :mirror
      $debootstrap.call debootstrap_args
    end

    def early_bootstrap(o)
      $log.info "Early stage debootstrap in #{o[:target]}"
      debootstrap '--foreign', o[:target], o[:debootstrap]
    end

    def late_bootstrap(o)
      $log.info "Late stage debootstrap in #{o[:target]}"
      $chroot.call [o[:target], '/debootstrap/debootstrap', '--second-stage']
    end

    def all_bootstrap(o)
      if File.file? o[:target_debootstrap]
        $log.info "Already Bootstrapped: #{o[:target_debootstrap]}"
        return
      end

      $log.info "Bootstrapping: #{o[:target]}"
      early_bootstrap o

      run_fixes o, "pre-bootstrap"
      late_bootstrap o
      run_fixes o, "post-bootstrap"

      FileUtils.touch o[:target_debootstrap]
    end

    def run_fixes(o, stage)
      o[:_roots].each do |root|
        o[:fixes].each do |fix_name|
          fix_source = File.join root, o[:fixes_dir], fix_name
          next unless File.file? fix_source

          fix_target = File.join o[:target_fixes], fix_name
          fix_run = File.join '/', o[:fixes_dir], fix_name

          unless File.file? fix_target
            $log.info "Copying fix #{fix_source} -> #{fix_target}"
            FileUtils.cp fix_source, fix_target
            FileUtils.chmod 0755, fix_target
          end

          $log.info "Running fix '#{fix_name}': #{fix_run} #{stage}"
          $chroot.call [o[:target], fix_run, stage]
        end
      end
    end

    def read_file(target, source_dir, file)
      from = file[:from]
      to = file[:to]
      mode = file[:mode] || 0644
      mode = mode.to_i(8) if mode.is_a? String

      raise "Missing 'from' declaration" if from.nil?
      raise "Missing 'to' declaration" if to.nil?

      files_pattern = File.join source_dir, from
      source_files = Dir.glob files_pattern

      return nil if source_files.empty?

      target_to = File.join(target, to)

      return {:files => source_files, :to => target_to, :mode => mode}
    end

    def install_manifest(o)
      return if o[:files].empty?

      $log.info "Installing Files"

      o[:_roots].each do |root|
        o[:files].each do |file|
          source_dir = File.join root, o[:files_dir]
          file = read_file(o[:target], source_dir, file)
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

    # for doing automated tasks inside of the chroot.
    def auto_chroot(env, target, *args)
      $log.info "chroot: #{args.join ' '}"
      env = (env || {}).merge(CHROOT_ENV)
      $chroot.call [target] + args, :env => env
    end

    def apt_get(env, target, *args)
      auto_chroot env, target, 'apt-get', '-y', '--force-yes', *args
    end

    def dpkg(env, target, *args)
      auto_chroot env, target, 'dpkg', *args
    end

    def install_packages(o, env, target, packages)
      return if packages.empty?

      options = []
      options << 'DPkg::NoTriggers=true'
      options << 'PackageManager::Configure=no'
      options << 'DPkg::ConfigurePending=false'
      options << 'DPkg::TriggersPending=false'

      options = options.map{|option| ['-o', option]}.flatten

      $log.info "Installing Packages"
      packages_repr = packages.join ' '

      $log.info "Installing Packages: #{packages_repr}"
      apt_get env, target, *(options + ['install', '--'] + packages)

      $log.info "Configuring Packages"
      run_fixes o, "pre-configure"
      dpkg env, target, '--configure', '-a'
      run_fixes o, "post-configure"
    end

    def sources_list(o, sources, name)
      sources_dir = File.join o[:target], 'etc', 'apt', 'sources.list.d'
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

    def read_pin(pinning)
        package = pinning[:package]
        pin = pinning[:pin]
        priority = pinning[:priority]

        raise "Missing 'package' declaration" if package.nil?
        raise "Missing 'pin' declaration" if pin.nil?
        raise "Missing 'priority' declaration" if priority.nil?

        {:package => package, :pin => pin, :priority => priority}
    end

    def write_apt_preferences(o)
      apt_preferences = File.join o[:target], 'etc', 'apt', 'preferences'

      return if File.file? apt_preferences

      $log.info "Writing Preferences #{apt_preferences}"

      File.open(apt_preferences, 'w', 0644) do |f|
        f.write "# generated by duck\n"

        o[:pinning].each do |pin|
          pin = read_pin(pin)

          f.write "Package: #{pin[:package]}\n"
          f.write "Pin: #{pin[:pin]}\n"
          f.write "Pin-Priority: #{pin[:priority]}\n"
          f.write "\n"
        end
      end
    end

    def prepare_apt(o)
      unless o.include? :build_sources
        raise "Required section 'build_sources' missing" 
      end

      sources_list o, o[:build_sources], 'build'

      unless o[:transports].empty?
        transports = o[:transports].map{|t| "apt-transport-#{t}"}
        $log.info "Installing extra transports: #{transports.join ' '}"
        apt_get o[:env], o[:target], 'update'
        apt_get o[:env], o[:target], 'install', *transports
      end

      if o.include? :main_sources
        sources_list o, o[:main_sources], 'main'
      end

      apt_get o[:env], o[:target], 'update'

      write_apt_preferences o
    end

    def setup_policy_rcd(o)
      policy_rcd = File.join o[:target], 'usr', 'sbin', 'policy-rc.d'

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

    def execute(o)
      all_bootstrap o
      prepare_apt o
      setup_policy_rcd o
      install_packages o, o[:env], o[:target], o[:packages]
      install_manifest o
      return 0
    end
  end
end

module Enter
  class << self
    def execute(o)
      $chroot.call [o[:target], o[:shell]], :env => o[:env]
    end
  end
end

def parse_options(args)
  o = Hash.new

  o[:target] = nil
  o[:files] = []
  o[:packages] = []
  o[:transports] = []
  o[:fixes] = []
  o[:pinning] = []
  o[:shell] = DEFAULT_SHELL
  o[:fixes_dir] = FIXES_DIR
  o[:files_dir] = FILES_DIR
  o[:_configs] = []

  action_name = :build

  opts = OptionParser.new do |opts|
    opts.banner = 'Usage: duck [action] [options]'

    opts.on('-t <dir>', '--target <dir>',
            'Build in the specified target directory') do |dir|
      o[:target] = dir
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
    action_name = args[0].to_sym
  end

  working_directory = Dir.pwd
  working_directory_config = File.join(working_directory, CONFIG_NAME)
  binary_root = File.dirname File.dirname(File.absolute_path($0))
  binary_config = File.join binary_root, CONFIG_NAME

  o[:target] = File.join working_directory, 'tmp', 'initrd' if o[:target].nil?
  o[:target_debootstrap] = File.join o[:target], '.debootstrap'

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
  return action_name, o
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
}

def main(args)
  action_name, o = parse_options args
  return 0 if o.nil? 
  prepare_options o

  action_module = ACTTIONS[action_name]

  if action_module.nil?
    $log.error "No such action: #{action_name}"
    return 1
  end

  begin
    execute_func = action_module.method(:execute)
  rescue
    $log.error "No such action: #{action_name}"
    return 1
  end

  execute_func.call(o)
end

exit main(ARGV) if __FILE__ == $0
