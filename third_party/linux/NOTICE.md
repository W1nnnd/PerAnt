# Android Linux runtime notices

The Android Linux environment is an aggregate of separately licensed components.
PerAnt's GPL-3.0-only license does not replace any upstream component's license.

| Component | Fixed source | License / copyright |
| --- | --- | --- |
| PRoot | OpenMinis/proot `2ca3bae3650988c0e098b4bb7686b79617b64194` | GPL-2.0-or-later, STMicroelectronics and upstream contributors; see `licenses/PRoot-COPYING.txt` and source headers. The linked executable is conveyed under GPLv3, including LGPLv3 talloc. |
| talloc 2.4.2 | Samba release tarball in `sources.lock.json` | LGPL-3.0-or-later, Andrew Tridgell (2004), Stefan Metzmacher (2006), and contributors. It is linked statically into PRoot; the complete source archive and recipe allow relinking. |
| External ELF loader | OpenMinis/OpenMinis `1a71df0f381cefde80bf912b723de6f9831bc177`, vendored Termux PRoot 5.1.107-70 | GPL-2.0-or-later; PRoot authors and Termux contributors. Corresponding Termux source: `4dba3afbf3a63af89b4d9c1a59bf2bda10f4d10f`; package recipe: `0ff4d49dad73ed7a62375504cf96326bb835e132`. |
| Standalone talloc compatibility header | Adapted from the fixed OpenMinis `deps/build_proot.sh` | OpenMinis contributors, GPLv3. Original script and attribution are retained in the verified source inputs. |
| Alpine 3.24.4 aarch64 minirootfs | Official, unmodified release archive; SHA256 fixed in `sources.lock.json` | Per-package licenses; exact installed package versions, origins and aports commits are in `alpine-packages.json`. |
| Python 3.14.10-r1 and its 13 additional runtime dependencies | Official Alpine v3.24 APKs, separately SHA256-pinned in `sources.lock.json` | Python is PSF-2.0; retain `licenses/Python-3.14.10-LICENSE.txt`. The dependency inventory retains each package's own license, source origin and aports commit. The signed APK bytes are installed offline into a staged rootfs by Alpine's package manager. |
| `text_to_markdown.py` | PerAnt's tracked source in `packages/perant_platform/android/src/main/python/` | Original PerAnt code, GPL-3.0-only. This is deterministic text formatting, not a model or semantic summarization implementation. |

Alpine includes GPL-2.0-only executables, MIT/BSD libraries, Apache-2.0 OpenSSL,
MPL-2.0 certificate data and Zlib-licensed code. These remain separately licensed
within the root filesystem. BusyBox and other Alpine executables are not linked
into the GPLv3 PerAnt application. No Linux kernel is included. Python and the
additional libraries are delivered as separate official Alpine packages rather
than changes to the original minirootfs archive.

The additional Python closure is: gdbm, libbz2, libexpat, libffi, libgcc,
libncursesw, libpanelw, libstdc++, mpdecimal, ncurses-terminfo-base, python3,
readline, sqlite-libs and xz-libs. Its compressed APK bytes total 10,829,637;
package metadata estimates an additional 32,630,860 installed bytes. The base
rootfs already includes the Mozilla CA bundle and OpenSSL libraries. No pip or
Python bytecode-cache package is included.

All 14 APKs carry the Alpine RSA signing key
`alpine-devel@lists.alpinelinux.org-616ae350.rsa.pub`, already present in the
fixed minirootfs. The host build verifies exact SHA256, package identity,
dependencies and signing-key name, and rejects additional installation scripts;
Alpine `apk add` performs the actual cryptographic signature check on device,
with networking disabled and without allowing untrusted packages. A rotating
repository index is recorded only as provenance; fixed APK hashes are the build
inputs. Removed upstream versions cause an explicit build failure, never a
silent upgrade.

Retained dependency texts cover Python, bzip2, expat, libffi, ncurses,
mpdecimal, SQLite, XZ and GCC's runtime exception; GPLv3 covers the gdbm and
readline license texts. See `licenses/Python-dependency-license-sources.json`
for exact source URLs, archive members and checksums. These notices and license
copies do not replace the complete corresponding-source distribution required
for a public binary release.

The vendored loader is retained because OpenMinis reports failures with its
locally rebuilt loader on some ROMs. Its original bytes are SHA256-pinned; the
source version and original Termux package recipe are available. A second loader
is built from that source for comparison, but byte identity and compatibility
across ROMs have not been established. Do not replace one silently.

`tool/prepare-linux-runtime` downloads and verifies the exact source archives.
For distribution, keep the corresponding source and build instructions available
alongside the APK, including all Alpine package patches/configuration and linked
dependencies. The current source lock is a provenance inventory, not a complete
Alpine corresponding-source bundle. Do not describe it as a completed release
source distribution. See `docs/LINUX_RUNTIME_SOURCES.md` for the remaining work.

The APK embeds this notice, the package inventory and the retained license texts
under `perant-linux/licenses/`. This is experimental runtime integration; device
execution and the host-file boundary require separate validation.

## Graphical desktop and office applications bundle (runtime v6)

The graphical Linux desktop uses the **official Alpine v3.24 aarch64** packages for TigerVNC 1.16.2 and the mature Xfce 4.20 desktop: xfce4-session 4.20.2, xfwm4 4.20.0, xfce4-panel 4.20.7, xfdesktop 4.20.1, xfce4-settings 4.20.4, xfconf 4.20.0, Thunar 4.20.8, Xfce Terminal 1.2.0, Mousepad 0.7.0 and Application Finder 4.20.0. Runtime v6 includes **LibreOffice 25.8.7.3-r0 Writer, Calc and Impress**, with the matching Simplified Chinese language and GTK integration packages. DejaVu/WenQuanYi fonts, xdotool, 14 matching Xfce language packages and their dependency closure are included. The original Alpine minirootfs archive and all 178 former v4 package versions are unchanged. The 355 desktop/application APKs total 417,378,446 compressed bytes and 1,103,522,175 declared installed bytes. These are storage figures, not runtime memory measurements. The former Openbox/Tint2/PCManFM/Xfe/xterm stack is replaced rather than shipped alongside Xfce. Broad desktop/office meta-packages are not installed; all required application dependencies remain explicit and pinned.

Exact package versions, origins, SHA256 digests, signing keys, dependencies, upstream URLs and reviewed installation scripts are in `desktop-packages.json` and `sources.lock.json`. The signed cache/font/MIME triggers and informational scripts are preserved and verified; only the staging rootfs is used for offline installation. `desktop-source-recipes.json` identifies the exact Alpine aports commits and SHA256 digests of the corresponding build recipes (including upstream source URLs, patches and source checksums).

The `licenses/Desktop-*` files retain 45 reference license texts at a fixed SPDX license-list-data commit and 81 actual upstream notice/copyright/license files extracted from matching official Alpine documentation/runtime packages, plus 23 copyright/license notices retained from the original DejaVu/WenQuanYi OpenType name tables and 33 original COPYING/COPYING.LIB/AUTHORS files from 15 checksum-verified Xfce source archives and the GdkPixbuf source archive. See `Desktop-package-license-sources.json` for immutable archive hashes, member paths and provenance. The 290 pinned aports recipes cover exactly the current package source origins. Removed desktop components' notices and generated package resources are pruned. The SPDX reference texts are not substitutes for package-specific copyright notices. These files and the recipe list are **not a complete corresponding-source bundle**; complete matching sources, patches, build information and remaining notices must accompany any future public binary distribution. This prototype has only been built for local development/testing, and is not being published by this task.

LibreOffice retains its MPL-2.0/other upstream terms and branding; its actual installed LICENSE, LICENSE.html and NOTICE are additionally retained in the license inventory. PerAnt does not claim authorship of LibreOffice. Browser functionality uses the Android native browser engine, integrated with the same PerAnt workspace; the system-provided engine is not a Linux APK in this inventory. The unsuccessful experimental Linux Firefox package and its 14 exclusive dependencies are not shipped in runtime v6. No browser sandbox or certificate-validation setting is disabled to accommodate PRoot. Local development probe evidence is retained separately and does not add Firefox binaries to this bundle.

PerAnt's fixed `start_desktop.sh`, its generated configuration, original procedural XPM icons and flat Xfwm window theme are GPL-3.0-only. The interface follows familiar desktop conventions and contains no Apple or Microsoft artwork. The script starts real Xvnc and xfce4-session, whose standard Failsafe clients manage windows, desktop, panel, settings and files. A private session D-Bus is used; no system D-Bus or hardware permission service is started. RFB uses an app-private Unix-domain socket, with TCP disabled; X11 clients use the native host's random MIT-MAGIC-COOKIE-1 authority file. Compositing, workspace thumbnails, automount/autorun and hardware/autostart helpers are disabled. Trusted XPM interface icons use the packaged legacy XPM loader; no image decoder sandbox is disabled. The package licenses continue to apply independently to their respective programs.

## Native PNG/XPM compatibility overlay

The official GdkPixbuf 2.44.7 APK and its signature are preserved. PerAnt separately builds an **LGPL-2.1-or-later GdkPixbuf 2.44.7** shared-library variant from the unmodified GNOME release archive (SHA256 `172f80e3626ec31520a970400f1a3694e04718f6c2cd2885f75250fb5a6995a4`, also verified against the fixed Alpine recipe's SHA512). The native PNG and legacy XPM loaders are built in; Glycin, JPEG, GIF, TIFF, other formats, Android decoders, introspection and thumbnailing are excluded from this variant. No Glycin or bubblewrap sandbox is disabled. The library is installed under `/opt/perant/lib` with its original SONAME, and only the graphical session and its child processes receive that guest-local `LD_LIBRARY_PATH`.

`native-codec.json` and `sources.lock.json` record the source, exact flags, recipe hash, 81 fixed official signed build APKs and the builder's immutable original Alpine minirootfs bytes. `tool/build-linux-codec` imports that rootfs into a dedicated ARM64 Docker image and builds with container networking disabled; it neither updates package indexes nor relies on a mutable Docker Hub tag. The build dependencies are not shipped in the application. The original recipe is `third_party/linux/native-codec/build.sh` (GPL-3.0-only); this does not replace the compiled library's LGPL license. Its original COPYING is retained as `licenses/Desktop-source-gdk-pixbuf-2.44.7-COPYING.txt`.

The separate library is 198,528 bytes with SHA256 `544c7eaedae251da320d8ee747edc015d2c3cfa6372bae694ad9a6992dbf7d22`. The runtime manifest covers its size and digest; initialization verifies the actual installed library and decodes real fixed PNG and XPM fixtures. Docker build verification also decodes both formats through that exact resulting library. This is an explicitly identified PerAnt compatibility build, not an official Alpine APK or a claim that arbitrary image formats are available. Matching sources, build inputs and these instructions must remain available for a public binary release.
