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

module Duck
  class << self
    include Logging
  end

  # environment to prevent tasks from being interactive.
  DEFAULT_SHELL = '/bin/bash'
  FILES_DIR = 'files'
  CONFIG_NAME = 'duck.yaml'
  CONFIG_ARRAYS = [:files, :packages, :transports, :preferences, :fixes, :services]

  ACTTIONS = {
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
    o[:keys_dir] = File.join working_directory, 'keys'
    o[:target] = File.join o[:temp], 'initrd'
    o[:initrd] = File.join o[:temp], 'initrd.gz'
    o[:gpg_homedir] = File.join o[:temp], 'gpg'
    o[:kernel] = File.join working_directory, 'vmlinuz'
    o[:no_minimize] = false
    o[:keep_minimized] = false
    o[:files] = []
    o[:services] = []
    o[:packages] = []
    o[:transports] = []
    o[:fixes] = []
    o[:preferences] = []
    o[:shell] = DEFAULT_SHELL
    o[:files_dir] = FILES_DIR
    o[:_configs] = []

    action_names = [:build, :pack]

    opts = OptionParser.new do |opts|
      opts.banner = 'Usage: duck [action] [options]'

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

      opts.on('--debug',
              'Switch on debug logging') do |dir|
        Logging::set_level Logger::DEBUG
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

    o[:bootstrap_status] = File.join o[:target], '.debootstrap'

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

    o[:_roots] = o[:_configs].map{|c| File.dirname c}

    o[:_configs].each do |config_path|
      log.info "Loading configuration from #{config_path}"
      config = deep_symbolize YAML.load_file(config_path)
      # Special keys treated as accumulated arrays over all configurations.
      CONFIG_ARRAYS.each{|n| o[n] += config.delete(n) || []}
      # Merge (overwrite) the rest.
      o.merge! config
    end
  end

  def self.main(args)
    action_names, o = parse_options args
    return 0 if o.nil?
    prepare_options o

    action_names.each do |action_name|
      action_class = ACTTIONS[action_name]

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
