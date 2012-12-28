require 'duck/spawn_utils'

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
    log.info "chroot: #{args.join ' '}"
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
