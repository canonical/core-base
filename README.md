# Core22 snap for snapd & Ubuntu Core

This is a base snap for snapd & Ubuntu Core that is based on Ubuntu 22.04

TODO: Not 22.04 actually yet, it will first build with impish rootfs and then we will switch to JJ when rootfs released.

# Building locally

To build this snap locally you need snapcraft. The project must be built as real root.

```
$ sudo snapcraft
```

# Writing code

The usual way to add functionality is to write a shell script hook
with the `.chroot` extenstion under the `hooks/` directory. These hooks
are run inside the base image filesystem.

Each hook should have a matching `.test` file in the `hook-tests`
directory. Those tests files are run relative to the base image
filesystem and should validates that the coresponding `.chroot` file
worked as expected.

The `.test` scripts will be run after building with snapcraft or when
doing a manual "make test" in the source tree.

# Bootchart

It is possible to enable bootcharts by adding `core.bootchart` to the
kernel command line. The sample collector will run until the system is
seeded (it will stop when the `snapd.seeded.service` stops). The
bootchart will be saved in the `ubuntu-data` partition, under
`/var/log/debug/boot<N>/`, `<N>` being the boot number since
bootcharts were enabled. If a chart has been collected by the
initramfs, it will be also saved in that folder.

**TODO** In the future, we would want `systemd-bootchart` to be started
only from the initramfs and have just one bootchart per boot. However,
this is currently not possible as `systemd-bootchart` needs some changes
so it can survive the switch root between initramfs and data
partition. With those changes, we could also have `systemd-bootchart` as
init process so we get an even more accurate picture.
