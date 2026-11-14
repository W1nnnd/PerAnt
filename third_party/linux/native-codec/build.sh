#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# PerAnt build recipe. The compiled GdkPixbuf library retains LGPL-2.1-or-later.
set -eu
umask 022
export SOURCE_DATE_EPOCH=1782864000
export CFLAGS='-O2 -fno-ident -ffile-prefix-map=/work=/usr/src/perant-codec'
export LDFLAGS='-Wl,--build-id=sha1'
# Every argument is an exact verified local APK path. Container networking is off.
/sbin/apk --repositories-file /dev/null add --no-network --no-cache --no-progress "$@"
python3 -I -B - <<'PY'
import ctypes
import hashlib
import json
from pathlib import Path
import os
import struct
import subprocess
import tarfile
import zlib

work = Path('/work')
inputs = json.loads((work / 'build-input.json').read_text())
source = work / 'source'
source.mkdir()
with tarfile.open('/inputs/' + inputs['sourceFile']) as archive:
    archive.extractall(source, filter='data')
tree = source / ('gdk-pixbuf-' + inputs['sourceVersion'])
subprocess.run(['meson', 'setup', '/work/build', str(tree),
                *inputs['mesonOptions']], check=True)
subprocess.run(['meson', 'compile', '-C', '/work/build', '-j', '4'], check=True)
library = work / 'build/gdk-pixbuf/libgdk_pixbuf-2.0.so.0.4400.7'
assert library.is_file(), 'Expected SONAME implementation missing'
output = Path('/output/libgdk_pixbuf-2.0.so.0')
subprocess.run(['strip', '--strip-unneeded', '-o', str(output), str(library)], check=True)
dynamic = subprocess.check_output(['readelf', '-d', str(output)], text=True)
assert 'libgdk_pixbuf-2.0.so.0' in dynamic
assert 'libglycin' not in dynamic and 'libjpeg' not in dynamic and 'libtiff' not in dynamic

# Decode real trusted PNG and XPM fixtures using the resulting shared library.
fixtures = work / 'fixtures'
fixtures.mkdir()
def chunk(kind, payload):
    return struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload))
png = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>2I5B', 2, 2, 8, 2, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b'\0\xff\0\0\0\xff\0\0\0\0\xff\xff\xff\xff')) + chunk(b'IEND', b'')
(fixtures / 'trusted.png').write_bytes(png)
(fixtures / 'trusted.xpm').write_text('/* XPM */\nstatic char *icon[] = {\n'
    '"2 2 2 1",\n"a c #2563eb",\n"b c #ffffff",\n"ab",\n"ba"\n};\n')
codec = ctypes.CDLL(str(output), mode=ctypes.RTLD_GLOBAL)
codec.gdk_pixbuf_new_from_file.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
codec.gdk_pixbuf_new_from_file.restype = ctypes.c_void_p
codec.gdk_pixbuf_get_width.argtypes = [ctypes.c_void_p]
codec.gdk_pixbuf_get_width.restype = ctypes.c_int
codec.gdk_pixbuf_get_height.argtypes = [ctypes.c_void_p]
codec.gdk_pixbuf_get_height.restype = ctypes.c_int
gobject = ctypes.CDLL('libgobject-2.0.so.0')
gobject.g_object_unref.argtypes = [ctypes.c_void_p]
results = []
for filename in ('trusted.png', 'trusted.xpm'):
    error = ctypes.c_void_p()
    pixbuf = codec.gdk_pixbuf_new_from_file(os.fsencode(fixtures / filename), ctypes.byref(error))
    assert pixbuf and not error.value, 'Native decode failed: ' + filename
    assert codec.gdk_pixbuf_get_width(pixbuf) == 2 and codec.gdk_pixbuf_get_height(pixbuf) == 2
    gobject.g_object_unref(pixbuf)
    results.append({'fixture': filename, 'width': 2, 'height': 2, 'decoded': True})
report = {'version': inputs['version'], 'sha256': hashlib.sha256(output.read_bytes()).hexdigest(),
          'sizeBytes': output.stat().st_size, 'platform': 'linux/arm64',
          'mesonOptions': inputs['mesonOptions'], 'decodes': results,
          'needed': dynamic}
Path('/output/verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('PERANT_NATIVE_CODEC_READY ' + report['sha256'], flush=True)
PY
