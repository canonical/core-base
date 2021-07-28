# Core22 snap for UbuntuCore22

This is a base snap for snapd that is based on Ubuntu 22.04

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

