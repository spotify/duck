require 'duck/spawn_utils'

module ChrootUtils
  include SpawnUtils

  CHROOT = 'chroot'
  APT_GET = 'apt-get'
  APT_KEY = 'apt-key'
  DPKG = 'dpkg'
  UPDATE_RCD = 'update-rc.d'
  SH = 'bash'

  CHROOT_ENV = {
    'DEBIAN_FRONTEND' => 'noninteractive',
    'DEBCONF_NONINTERACTIVE_SEEN' => 'true',
    'LC_ALL' => 'C',
    'LANGUAGE' => 'C',
    'LANG' => 'C',
  }

  def chroot(args, options={})
    spawn [CHROOT] + args, options
  end

  # for doing automated tasks inside of the chroot.
  def auto_chroot(args, opts={})
    log.debug "chroot: #{args.join ' '}"
    opts[:env] = (opts[:env] || {}).update(@chroot_env || {}).merge(CHROOT_ENV)
    chroot [@target] + args, opts
  end

  def in_apt_get(*args)
    auto_chroot [APT_GET, '-y', '--force-yes'] + args
  end

  def in_apt_key(args, opts)
    auto_chroot [APT_KEY] + args, opts
  end

  def in_dpkg(*args)
    auto_chroot [DPKG] + args
  end

  def in_shell(command)
    auto_chroot [SH, '-c', command]
  end

  def in_update_rcd(*args)
    auto_chroot [UPDATE_RCD] + args
  end
end
