# PerAnt 0.9.0 source closure review

Reviewed 2026-11-16 against the fixed aports recipe trees and checksum-verified source archives collected for the current runtime. This report records a technical source-inventory review. It does not claim an independent clean rebuild of every upstream binary or bit-identical compiler output.

## Scope and evidence

- Examined the collected APKBUILD files for direct fetch commands, Cargo use, `net` build options, explicit external static dependencies and bundled-vs-system switches. Full aports directories retain build/install scripts and patches rather than only APKBUILD text.
- Searched every regular recipe file for `Cargo.lock`, `Cargo.toml` and git source references. Only the two copies of glycin's `bump-nix.patch` modify Cargo metadata. No other recipe patch changed a Cargo registry/git source in the collected trees.
- Extracted selected source members from Mesa 26.1.6, LibreOffice 25.8.7.3 and GStreamer / base / bad plugins 1.28.3 into `review-extract/` for inspection. Archive inputs remain in `distfiles/` with their original SHA512 identities.

## Resolved issues

### Glycin / libglycin

The fixed `bump-nix.patch` changes upstream Cargo.lock from nix 0.30.1 to 0.31.2 and changes its checksum. The review supplied the exact additional registry archive in [cargo-additional-reviewed.json](../third_party/linux/source-reviews/cargo-additional-reviewed.json):

- nix 0.31.2 SHA256 `5d6d0705320c1e6ba1d912b5e37cf18071b6c2e9b7fa8215a1e8a7651966f5d3`.

The patch also replaces tempfile's reference from getrandom 0.3.4 to 0.4.1. Both registry versions already occur in the upstream lock, and the 0.4.1 archive is present. nix 0.31.2's nonoptional dependency bounds are satisfied by lock entries already collected: bitflags 2.11.0, cfg-if 1.0.4, libc 0.2.183 (minimum requirement 0.2.181), cfg_aliases 0.2.1. Its optional memoffset 0.9.1 is also present. The fixed workspace enables fs/resource/signal; no newly required pin-utils dependency was found for those features.

The original lock versions can remain as a conservative source superset; they must not be described as the only patched build inputs.

### Mesa

Mesa uses explicit Meson Rust subprojects, not a Cargo.lock. Its APKBUILD supplies six Rust archives and replaces six upstream wrap files before building. The review additionally enumerated every one of the fixed source tree's 29 `subprojects/*-rs.wrap` files and copied their exact name/version/source_hash into [cargo-additional-reviewed.json](../third_party/linux/source-reviews/cargo-additional-reviewed.json). This intentionally retains superseded default versions as well as the APKBUILD's replacement versions.

All Rust subproject references in `subprojects/packagefiles/*/meson.build` have matching collected wrap identities; the reference-minus-wrap set is empty. System-library fallbacks retain their build declarations in the full Mesa source tree. This review did not infer that every optional non-Rust fallback was used by the published Alpine build.

### GStreamer

GStreamer's Rust use is the PTP helper. Its 12 source modules (including `rand`, `ffi`, `clock`, `net`) are local to `libs/gst/helpers/ptp/`; `main.rs` declares these modules directly and uses the Rust standard library. The reviewed GStreamer archive contains no Cargo.toml/Cargo.lock requiring additional crates. The base/bad plugin source archives inspected did not introduce Cargo registry inputs.

### LibreOffice

The fixed APKBUILD uses `--disable-fetch-external`, `--with-external-tar="$srcdir"`, `--with-system-libs` and explicit bundled exceptions. All 22 externally archived inputs that match the source's `download.lst` were independently checked against that file's SHA256 values, in addition to the collector's APKBUILD SHA512 checks. All 22 match; details are in [libreoffice-download-review.json](../third_party/linux/source-reviews/libreoffice-download-review.json).

These include dragonbox, frozen, libeot, dtoa, pdfium, Skia, zxcvbn-c, Java WebSocket and the selected Java sources. SANE uses the included `external/sane/inc` header through RepositoryExternal.mk. The old libfixmath configure switch does not declare a source download, and no extra libfixmath external archive/use entry was found in download.lst/RepositoryExternal.mk. No additional build-time network fetch was identified by this review. Full core/dictionaries/translations archives retain their own vendored content and notices.

### Explicit static dependencies

BusyBox's exact static inputs have been resolved against the official aarch64 build log by the collecting agent: utmps-static 0.1.3.2-r0 and skalibs-static 2.14.5.0-r0, with actual final `-Bstatic -lutmps -lskarnet` linkage. Both fixed recipe trees and original source archives are retained, in addition to the newer versions needed by direct runtime packages. The official log is included in the bundle evidence.

Other explicit static references found are apk-tools' separate `apk-tools-static` output (not included in the current package inventory), GLib's static subpackage (not included), and util-linux's utmps build dependency. The shipped util-linux inventory is libblkid/libmount/libuuid/mcookie, not the login/runuser binaries; both reviewed utmps/skalibs source generations are retained conservatively. [explicit-static-dependencies-review.json](../third_party/linux/source-reviews/explicit-static-dependencies-review.json) records the source lines. Producing a static subpackage in an upstream recipe alone was not mistaken for evidence that PerAnt ships that subpackage.

## Build-time network review

Only glycin, libglycin and librsvg mark network access for Cargo during the reviewed builds. Other `net` annotations explicitly concern upstream tests (BusyBox, curl, Python). No direct APKBUILD `curl`, `wget`, `git clone` or `git fetch` build command introducing an unrecorded source was identified. Source URLs, test URLs and runtime networking descriptions were distinguished from actual source fetches.

## Remaining material gaps

Within the source-inventory areas reviewed above, **no further concrete missing source archive or modified Cargo dependency remains identified after the nix and Mesa additions and the exact BusyBox static-input collection**. Final publication still requires the collecting agent's archive-wide hash verification, the native-runtime inputs and fixed Termux build framework and build recipes, the matching PerAnt source revision, APK/runtime hash binding, and successful packaging/extraction verification. Those packaging checks are separate from this review and must not be inferred from it.

No GitHub CI tests were run. No application runtime source was changed by this review.
