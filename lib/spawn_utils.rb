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
    suite = options[:suite]
    raise "Missing required option 'suite'" unless suite
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
