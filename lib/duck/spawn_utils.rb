module SpawnUtils
  SH = 'sh'
  DEBOOTSTRAP = 'debootstrap'
  GPG = 'gpg'
  QEMU = 'qemu-system-x86_64'

  class ExitError < Exception
    attr_accessor :exitcode

    def initialize(message, exitcode=1)
      @exitcode = exitcode
      super message
    end
  end

  def spawn(args, options={})
    env = options[:env] || {}

    repr = args.map do |i|
      if i.nil?
        '<nil>'
      elsif i.include? ' '
        "\"#{i}\""
      else
        i
      end
    end.join " "

    log.debug "exec: #{repr}"

    stdin_r = nil
    stdout_w = nil

    if options[:input_file]
      stdin_r = options[:input_file]
    end

    if options[:output_file]
      stdout_w = options[:output_file]
    end

    child_pid = fork do
      ENV.update env
      $stdin.reopen stdin_r unless stdin_r.nil?
      $stdout.reopen stdout_w unless stdout_w.nil?
      exec *args
      exit 255
    end

    Process.wait child_pid
    exit_status = $?.exitstatus

    if exit_status != 0
      raise ExitError.new "#{repr}: Subprocess returned non-zero exit status", exit_status
    end

    exit_status
  end

  def shell(command)
    spawn [SH, '-c', command]
  end

  def debootstrap(suite, target, options={})
    # Extra arguments have to be early when running debootstrap.
    args = Array.new(options[:extra] || [])
    args << suite << target
    args << options[:mirror] if options.include? :mirror
    spawn [DEBOOTSTRAP] + args
  end

  def gpg(args, options={})
    gpg_args = []
    gpg_args << "--homedir" << options[:homedir] if options[:homedir]
    gpg_args << "--keyserver" << options[:keyserver] if options[:keyserver]
    gpg_args += args
    spawn [GPG] + gpg_args
  end

  def qemu(*args)
    spawn [QEMU] + args
  end
end
