require 'optparse'
require 'fileutils'
require 'yaml'
require 'find'

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
  FIXES_DIR = 'fixes'
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
    unless File.directory? o[:target]
      log.info "Creating target directory: #{o[:target]}"
      FileUtils.mkdir_p o[:target]
    end

    raise "No configuration found" if o[:_configs].empty?

    o[:target_fixes] = File.join o[:target], o[:fixes_dir]

    FileUtils.mkdir_p o[:target] unless File.directory? o[:target]
    FileUtils.mkdir_p o[:target_fixes] unless File.directory? o[:target_fixes]

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
