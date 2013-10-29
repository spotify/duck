require 'optparse'
require 'fileutils'
require 'yaml'
require 'find'
require 'logger'

require 'duck/logging'
require 'duck/build'
require 'duck/enter'
require 'duck/pack'
require 'duck/qemu'
require 'duck/version'

module Duck
  class << self
    include Logging
  end

  # environment to prevent tasks from being interactive.
  DEFAULT_SHELL = '/bin/bash'
  CONFIG_NAME = 'duck.yaml'
  CONFIG_ARRAYS = [:files, :packages, :transports, :preferences, :fixes, :services, :sources]

  ACTIONS = {
    :build => Duck::Build,
    :enter => Duck::Enter,
    :pack => Duck::Pack,
    :qemu => Duck::Qemu,
  }

  def self.resource_path(path)
    File.expand_path File.join('..', '..', path), __FILE__
  end

  def self.parse_options(args)
    o = Hash.new

    working_directory = Dir.pwd

    o[:temp] = File.join working_directory, 'tmp'
    o[:target] = File.join o[:temp], 'initrd'
    o[:initrd] = File.join working_directory, 'duck-initrd.img'
    o[:initrd_kernel] = File.join working_directory, 'duck-vmlinuz'
    o[:gpg_homedir] = File.join o[:temp], 'gpg'
    o[:kernel] = File.join working_directory, 'vmlinuz'
    o[:no_minimize] = false
    o[:append] = nil
    o[:keep_minimized] = false
    o[:keep_builddir]  = false
    o[:shell] = DEFAULT_SHELL
    o[:_configs] = []
    o[:_roots] = []
    o[:strip] = false

    CONFIG_ARRAYS.each do |array|
      o[array] = []
    end

    action_names = [:build, :pack]

    opts = OptionParser.new do |opts|
      opts.banner = 'Usage: duck [action] [options]'

      opts.separator "Actions:"

      ACTIONS.each do |k, klass|
        opts.separator "    #{k}: #{klass.doc}"
      end

      opts.separator "Options:"

      opts.on('-b <dir>', '--builddir <dir>',
              'Use the following directory for the build ') do |dir|
        unless dir =~ /^\//
          dir=File.join working_directory+'/'+dir
        end
        puts "dir is #{dir}"
        o[:temp] = dir
        o[:target] = File.join o[:temp], 'initrd'
        o[:gpg_homedir] = File.join o[:temp], 'gpg'
      end

      opts.on('-t <dir>', '--target <dir>',
              'Build in the specified target directory') do |dir|
        o[:target] = dir
      end

      opts.on('--no-minimize',
              'Do not minimize the installation right before packing') do |dir|
        o[:no_minimize] = true
      end

      opts.on('--keep-minimized',
              'Keep the minimized version of the initrd around') do |dir|
        o[:keep_minimized] = true
      end

      opts.on('--keep-builddir',
              'Keep the build directory around') do |dir|
        o[:keep_builddir] = true
      end

      opts.on('--debug',
              'Switch on debug logging') do |dir|
        Logging::set_level Logger::DEBUG
      end

      opts.on('-o <file>', '--output <file>',
              'Output initrd to <file>, default is ./duck-initrd.img') do |path|
        o[:initrd] = File.expand_path(path)
      end

      opts.on('-z <file>', '--vmlinuz <file>', 
              'Copy the initrd\'s kernel to <file>, default is ./duck-vmlinuz') do |path|
        o[:initrd_kernel] = File.expand_path(path)
      end

      opts.on('-k <kernel>', '--kernel <kernel>',
              'Specify kernel to use when running qemu') do |path|
        o[:kernel] = File.expand_path(path)
      end

      opts.on('-a <append>', '--append <append>',
              'Specify kernel options to append') do |append|
        o[:append] = append
      end

      opts.on('-c <path>', '--config <path>',
              'Use the specified configuration path') do |path|
        o[:_configs] << File.expand_path(path)
      end

      opts.on('-s <shell>', '--shell <shell>',
              'Set the shell to use when chrooting') do |shell|
        o[:shell] = shell
      end

      opts.on('-x', '--strip', 'Strip files in the initrd') do
        raise "No strip utility found." unless system("which strip >/dev/null")
        o[:strip] = true
      end

      opts.on('-h', '--help', 'Show this message') do
        puts opts
        return nil
      end

      opts.on('-v', '--version', 'Show version') do
        puts "duck: version #{VERSION}"
        return nil
      end
    end

    args = opts.parse! args

    unless args.empty?
      action_names = args.map{|a| a.to_sym}
    end

    # add default configuration if none is specified.
    if o[:_configs].empty?
      o[:_configs] << File.join(working_directory, CONFIG_NAME)
    end

    o[:_configs] = [resource_path(CONFIG_NAME)] + o[:_configs]

    o[:_configs].uniq!
    o[:_configs].reject!{|i| not File.file? i}
    return action_names, o
  end

  def self.deep_symbolize(o)
    return o.map{|i| deep_symbolize(i)} if o.is_a? Array
    return o unless o.is_a? Hash
    c = o.clone
    c.keys.each {|k| c[k.to_sym] = deep_symbolize(c.delete(k))}
    return c
  end

  def self.prepare_options(o)
    raise "No configuration found" if o[:_configs].empty?

    [:target].each do |s|
      next if File.directory? o[s]
      log.info "Creating directory '#{s}' on #{o[s]}"
      FileUtils.mkdir_p o[s]
    end

    unless File.directory? o[:gpg_homedir]
      log.info "Creating directory GPG home directory on #{o[:gpg_homedir]}"
      FileUtils.mkdir_p o[:gpg_homedir]
      FileUtils.chmod 0700, o[:gpg_homedir]
    end

    o[:_configs].each do |config_path|
      log.info "Loading configuration from #{config_path}"
      config = deep_symbolize YAML.load_file(config_path)
      root = File.dirname config_path
      # Special keys treated as accumulated arrays over all configurations.

      CONFIG_ARRAYS.each do |n|
        o[n] += (config.delete(n) || []).map{|i| [root, i]}
      end

      # Merge (overwrite) the rest.
      o.merge! config
      o[:_roots] << root
    end
  end

  def self.main(args)
    action_names, o = parse_options args
    return 0 if o.nil?
    prepare_options o

    action_names.each do |action_name|
      action_class = ACTIONS[action_name]

      if action_class.nil?
        log.error "No such action: #{action_name}"
        return 1
      end

      action_instance = action_class.new o
      action_instance.execute
    end

    return 0
  end
end

if __FILE__ == $0
    exit Duck::main(ARGV)
end
