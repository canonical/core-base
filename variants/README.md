# Build variants of the core26 base snap

This repository builds several variants of the core26 base snap. All
variants share the same snapcraft project and build pipeline; a variant
only changes what the name implies (extra packages, extra files, extra
wiring), never the build system itself.

# Selecting a variant

The selected variant is communicated to the build through the
`SNAP_BUILD_VARIANT` variable, which the `build-env` part picks up:

* **Local builds**: write a `build-env` file into the project root
  containing a single line, e.g. `SNAP_BUILD_VARIANT=example`, before
  running `snapcraft pack` (or use `tools/build-variant.sh`, which
  does this for you and removes the file afterwards).
* **Launchpad builds**: nothing to do. The `build-env` part parses
  `SNAPCRAFT_IMAGE_INFO` for the recipe build URL
  (`.../core26-<variant>/+build/<id>`) and derives the variant name
  from it. The Launchpad recipe must be named `core26-<variant>`.

Consequences of a selected variant (all handled by existing machinery,
no per-variant code needed):

* the snap version becomes `<date>+<variant>`;
* `SNAP_BUILD_NAME` (staged `build-env` file) becomes
  `core26-<variant>`;
* parts and hooks can branch on `$SNAP_BUILD_VARIANT` (e.g. the
  `chisel-libs` part adds the `cloud-init_bins` slice for the
  `cloud-init` variant, hooks `005`/`011` do cloud-init wiring).

# Variant payload

A variant may carry a payload directory, `variants/<variant>/`, whose
contents are applied to the rootfs during the build (see the `install`
target in the Makefile, which calls `tools/apply-variant-payload.sh`
after the base `static/` files are copied and before the hooks run):

| knob | path | effect |
|---|---|---|
| extra files | `variants/<v>/static/` | copied verbatim into the rootfs, on top of the base `static/` files (same-path variant file wins). Top-level hidden files are not copied, mirroring the base `static/` copy. |
| fstab | `variants/<v>/fstab.d/*.conf` | appended to `/etc/fstab`, in glob order |
| tmpfiles.d | `variants/<v>/writable.conf.d/*.conf` | appended to `/usr/lib/tmpfiles.d/core-writable.conf`, in glob order |

Rules for the fragment knobs:

* `fstab.d/` entries follow the same conventions as `static/etc/fstab`
  (see the "Writable paths" section of the top-level README): bind
  mounts of `/writable/system-data/...`, with `x-initrd.mount` for
  `/etc` paths.
* every `C` line added through `writable.conf.d/` needs a matching
  fstab entry and matching template data in `/usr/share/factory`
  (ship the latter through the `static/` knob); the
  `993-factory-files` build-time test enforces this.
* `d` and `f` lines may additionally target paths nested under an
  existing mount (no fstab entry of their own), to pin individual
  entries inside a mounted tree — the `993-factory-files` build-time
  test accepts a nested path when the mount it lives under is
  declared.
* fragment files must be complete lines; a comment-only or empty file
  is valid and changes nothing.

# Staged payload (ELFs and other build-time content)

Content that cannot be carried in the payload tree — architecture
specific binaries resolved from archive debs at build time, or binaries
built from in-tree source — is staged by the variant's snapcraft parts
into `$CRAFT_STAGE/<variant>-payload/`. `apply-variant-payload.sh`
copies that tree into the rootfs on the variant's builds only (and
never on regular builds). The `995-variant-payload` build-time test
verifies both directions: the staged payload is present on variant
builds, and nothing leaks into regular builds.

# Multiarch paths

A payload that must land under `/usr/lib/<triplet>` (or otherwise
express the Debian multiarch triplet) uses the `@MULTIARCH@`
placeholder in directory names, file contents and symlink targets;
`apply-variant-payload.sh` substitutes the build environment's
triplet at apply time, so the payload lands at the build
architecture's multiarch paths instead of silently assuming amd64.

# Snap naming

`snapcraft.yaml` keeps the static project name `core26` (changing it
would swap snapcraft's project-keyed LXD build instance and lose the
incremental build state). `tools/build-variant.sh` therefore packs the
build result a second time from the build instance's prime directory
with `meta/snap.yaml`'s `name:` patched to `core26-<variant>`, done as
real root inside the LXD container so file ownership and the `/dev`
device nodes survive the round trip. The result is
`core26-<variant>_<version>_<arch>.snap`.

# Existing variants

* `example` — a tiny demonstration payload exercising every knob: one
  extra file, one writable fstab mount with its `C` line and factory
  template, and one `d` line nested under that mount. It exists so the
  machinery (selection, payload application, naming, architecture
  declaration) is exercised end to end with content, in CI, without
  carrying any product payload.
* `cloud-init` — adds cloud-init (no payload directory; see the
  `chisel-libs` part and hooks `005`/`011`).
