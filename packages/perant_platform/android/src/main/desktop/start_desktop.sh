#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Original PerAnt desktop configuration and icons. Native host binds private dirs.
set -eu
umask 077
[ "$#" -eq 3 ] || exit 64
display=$1
width=$2
height=$3
case "$display:$width:$height" in *[!0-9:]*|'') exit 64 ;; esac
[ "$display" -ge 1 ] && [ "$display" -le 32767 ] || exit 64
[ "$width" -ge 256 ] && [ "$width" -le 1920 ] || exit 64
[ "$height" -ge 256 ] && [ "$height" -le 1280 ] || exit 64
[ -d /run/perant-desktop ] && [ -f /run/perant-desktop/Xauthority ] || exit 65
export DISPLAY=:$display
export XAUTHORITY=/run/perant-desktop/Xauthority
export XDG_CONFIG_HOME=/run/perant-desktop/config
export XDG_CACHE_HOME=/run/perant-desktop/cache
export XDG_DATA_HOME=/run/perant-desktop/data
export XDG_RUNTIME_DIR=/run/perant-desktop
export HOME=/root
export LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 LANGUAGE=zh_CN:zh
export LIBGL_ALWAYS_SOFTWARE=1
# Desktop processes use the manifest-verified native PNG/XPM-only overlay.
# The official signed APKs and their decoder/sandbox configuration are unchanged.
export LD_LIBRARY_PATH=/opt/perant/lib
export GTK_USE_PORTAL=0 GSETTINGS_BACKEND=keyfile NO_AT_BRIDGE=1
export GIO_USE_VFS=local GIO_USE_VOLUME_MONITOR=unix
export DESKTOP_SESSION=xfce XDG_CURRENT_DESKTOP=XFCE XDG_SESSION_DESKTOP=xfce
export XDG_SESSION_TYPE=x11 GDK_BACKEND=x11 XDG_MENU_PREFIX=xfce-
export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/perant-desktop/bus
mkdir -p /tmp/.X11-unix "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME" "$XDG_DATA_HOME"
chmod 1777 /tmp /tmp/.X11-unix
rm -f /run/perant-desktop/desktop.ready /run/perant-desktop/desktop.ready.part

# All generated paths belong to this session. No launchers/config are written
# into the user's workspace. The source below runs with isolated Python flags.
/usr/bin/python3 -I -B - "$width" "$height" <<'PY'
import os
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

base = Path('/run/perant-desktop')
config = base / 'config'
data = base / 'data'
width, height = map(int, sys.argv[1:])

def put(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding='utf-8')

# Trusted, original XPM icons avoid image decoder/helper namespaces on Android.
# No decoder sandbox is disabled. Thumbnails of workspace images are off.
palette = {' ': 'None', 'b': '#2563eb', 'l': '#60a5fa', 'p': '#dbeafe',
           'd': '#1e293b', 'w': '#ffffff', 'g': '#94a3b8', 's': '#e2e8f0'}
iconroot = data / 'icons/PerAnt'
icons = iconroot / '64x64/apps'

def icon(name, kind):
    image = [[' '] * 64 for _ in range(64)]
    def rect(x0, y0, x1, y1, color):
        for y in range(y0, y1):
            for x in range(x0, x1):
                image[y][x] = color
    def line(x0, y0, x1, y1, color, weight=3):
        n = max(abs(x1-x0), abs(y1-y0), 1)
        for i in range(n+1):
            x = round(x0 + (x1-x0)*i/n)
            y = round(y0 + (y1-y0)*i/n)
            rect(max(x-weight//2, 0), max(y-weight//2, 0),
                 min(x+weight//2+1, 64), min(y+weight//2+1, 64), color)
    if kind == 'folder':
        rect(5, 13, 29, 22, 'l'); rect(5, 19, 59, 55, 'b')
        rect(8, 25, 56, 51, 'l'); rect(8, 25, 56, 30, 'p')
    elif kind == 'terminal':
        rect(5, 8, 59, 57, 'd'); rect(8, 11, 56, 19, 'g')
        line(15, 29, 24, 36, 'w'); line(24, 36, 15, 43, 'w')
        line(31, 43, 46, 43, 'l')
    elif kind == 'document':
        rect(13, 5, 49, 59, 'b'); rect(16, 8, 46, 56, 'w')
        rect(34, 8, 46, 21, 'p')
        for y in (28, 36, 44): rect(22, y, 40, y+3, 'g')
    elif kind == 'spreadsheet':
        rect(10, 6, 54, 58, 'b'); rect(14, 10, 50, 54, 'w')
        rect(18, 16, 46, 23, 'l')
        for x in (18, 31, 44): rect(x, 27, x+2, 48, 'g')
        for y in (27, 37, 47): rect(18, y, 46, y+2, 'g')
    elif kind == 'presentation':
        rect(5, 8, 59, 47, 'b'); rect(9, 12, 55, 43, 'w')
        rect(15, 18, 46, 22, 'l'); rect(15, 28, 37, 31, 'g')
        rect(15, 35, 43, 38, 'g'); rect(30, 47, 34, 56, 'd')
        rect(19, 55, 45, 59, 'd')
    elif kind == 'desktop':
        rect(4, 8, 60, 48, 'd'); rect(8, 12, 56, 43, 'p')
        rect(28, 48, 36, 55, 'g'); rect(18, 55, 46, 59, 'd')
    elif kind == 'settings':
        for y in range(10, 54):
            for x in range(10, 54):
                radius = ((x-32)**2 + (y-32)**2)**0.5
                if 13 < radius < 21: image[y][x] = 'b'
        for x0, y0, x1, y1 in [(28, 4, 36, 17), (28, 47, 36, 60),
                               (4, 28, 17, 36), (47, 28, 60, 36),
                               (11, 11, 21, 21), (43, 11, 53, 21),
                               (11, 43, 21, 53), (43, 43, 53, 53)]:
            rect(x0, y0, x1, y1, 'b')
    elif kind == 'keyboard':
        rect(3, 14, 61, 50, 'd'); rect(6, 17, 58, 47, 'p')
        for y in (22, 31):
            for x in range(11, 54, 9): rect(x, y, x+5, y+5, 'd')
        rect(16, 40, 48, 44, 'd')
    elif kind == 'mouse':
        for y in range(7, 57):
            for x in range(16, 48):
                if ((x-32)/16)**2 + ((y-32)/25)**2 < 1: image[y][x] = 'b'
        rect(30, 9, 34, 29, 'w'); rect(19, 28, 45, 31, 'p')
    elif kind == 'start':
        for x in (8, 35):
            for y in (8, 35): rect(x, y, x+21, y+21, 'b')
    elif kind == 'back':
        line(43, 13, 22, 32, 'd', 5); line(22, 32, 43, 51, 'd', 5)
    elif kind == 'forward':
        line(21, 13, 42, 32, 'd', 5); line(42, 32, 21, 51, 'd', 5)
    elif kind == 'up':
        line(13, 39, 32, 20, 'd', 5); line(32, 20, 51, 39, 'd', 5)
    elif kind == 'close':
        line(17, 17, 47, 47, 'd', 5); line(17, 47, 47, 17, 'd', 5)
    elif kind == 'add':
        rect(28, 10, 36, 54, 'b'); rect(10, 28, 54, 36, 'b')
    elif kind == 'search':
        for y in range(8, 46):
            for x in range(8, 46):
                radius = ((x-27)**2 + (y-27)**2)**0.5
                if 13 < radius < 19: image[y][x] = 'd'
        line(40, 40, 55, 55, 'd', 6)
    elif kind == 'save':
        rect(9, 7, 55, 57, 'b'); rect(18, 9, 45, 27, 'p')
        rect(18, 36, 46, 55, 'w'); rect(36, 12, 41, 23, 'd')
    else:
        rect(12, 12, 52, 52, 'g'); rect(20, 20, 44, 44, 'w')
    colors = ['"%s c %s",' % (key, value) for key, value in palette.items()]
    pixels = ['"' + ''.join(row) + '",' for row in image]
    put(icons / (name + '.xpm'), '/* XPM */\n'
        '/* Original PerAnt icon; GPL-3.0-only */\nstatic char *icon[] = {\n"64 64 %d 1",\n' % len(palette)
        + '\n'.join(colors + pixels).rstrip(',') + '\n};\n')

for name, kind in [('folder', 'folder'), ('utilities-terminal', 'terminal'),
                   ('text-x-generic', 'document'), ('user-desktop', 'desktop'),
                   ('office-writer', 'document'),
                   ('office-calc', 'spreadsheet'), ('office-impress', 'presentation'),
                   ('preferences-system', 'settings'), ('input-keyboard', 'keyboard'),
                   ('input-mouse', 'mouse'),
                   ('perant-start', 'start'), ('go-previous', 'back'),
                   ('go-next', 'forward'), ('go-up', 'up'),
                   ('window-close', 'close'), ('list-add', 'add'),
                   ('edit-find', 'search'), ('document-save', 'save')]:
    icon(name, kind)

aliases = {'folder': ['user-home', 'user-documents', 'folder-open', 'folder-documents',
           'folder-download', 'folder-pictures', 'inode-directory', 'system-file-manager',
           'gtk-directory', 'gtk-open', 'document-open', 'gtk-home', 'go-home'],
           'utilities-terminal': ['terminal', 'xterm', 'application-x-executable'],
           'text-x-generic': ['application-octet-stream', 'unknown', 'empty',
           'text-plain', 'text-x-markdown', 'accessories-text-editor', 'gtk-file',
           'document-new', 'gtk-new', 'application-x-desktop'],
           'go-previous': ['gtk-go-back'], 'go-next': ['gtk-go-forward'],
           'go-up': ['gtk-go-up'], 'window-close': ['gtk-close', 'edit-delete'],
           'document-save': ['gtk-save', 'document-save-as'],
           'edit-find': ['gtk-find', 'system-search'],
           'user-desktop': ['video-display', 'org.xfce.settings.display', 'org.xfce.workspaces'],
           'input-keyboard': ['preferences-desktop-keyboard', 'org.xfce.settings.keyboard'],
           'input-mouse': ['preferences-desktop-mouse', 'org.xfce.settings.mouse'],
           'preferences-system': ['preferences-desktop', 'org.xfce.settings.manager',
           'org.xfce.settings.appearance', 'org.xfce.settings.accessibility',
           'org.xfce.settings.color', 'org.xfce.settings.default-applications',
           'org.xfce.settings.editor', 'org.xfce.xfwm4', 'org.xfce.xfwm4-tweaks',
           'org.xfce.panel', 'preferences-desktop-wallpaper']}
aliases['folder'] += ['org.xfce.thunar', 'org.xfce.filemanager']
aliases['utilities-terminal'] += ['org.xfce.terminal', 'org.xfce.terminalemulator']
aliases['text-x-generic'] += ['org.xfce.mousepad']
for source, names in aliases.items():
    for name in names:
        (icons / (name + '.xpm')).symlink_to(source + '.xpm')
put(iconroot / 'index.theme', '[Icon Theme]\nName=PerAnt\nComment=Original fixed session icons\n'
    'Directories=64x64/apps\nInherits=hicolor\n\n[64x64/apps]\n'
    'Size=64\nType=Scalable\nMinSize=16\nMaxSize=128\nContext=Applications\n')

put(config / 'user-dirs.dirs', 'XDG_DESKTOP_DIR="/run/perant-desktop/Desktop"\n'
    'XDG_DOCUMENTS_DIR="/workspace"\nXDG_DOWNLOAD_DIR="/workspace"\n')
put(config / 'gtk-3.0/settings.ini', '[Settings]\ngtk-theme-name=Adwaita\n'
    'gtk-icon-theme-name=PerAnt\ngtk-font-name=DejaVu Sans 18\n'
    'gtk-enable-animations=0\ngtk-application-prefer-dark-theme=0\n')
put(config / 'gtk-3.0/gtk.css', '''button, entry, menuitem { min-height: 38px; }
button { padding: 5px 10px; }
entry { padding: 6px 10px; }
menuitem { padding: 8px 14px; }
scrollbar slider { min-width: 18px; min-height: 36px; }
#applicationsmenu-button { min-width: 82px; padding: 0; }
.xfce4-panel button { min-height: 78px; min-width: 78px; padding: 0; }
.xfce4-panel { background-color: #f8fafc; color: #1e293b; }
''')

commands = {
    'files': '/usr/bin/Thunar /workspace',
    'terminal': '/usr/bin/xfce4-terminal --disable-server --working-directory=/workspace --title="PerAnt Terminal" --maximize',
    'writer': 'env SAL_ENABLE_FILE_LOCKING=1 SAL_USE_VCLPLUGIN=gtk3 /usr/lib/libreoffice/program/soffice.bin -env:URE_BOOTSTRAP=vnd.sun.star.pathname:/usr/lib/libreoffice/program/fundamentalrc -env:UserInstallation=file:///root/.perant-office --nologo --writer',
    'calc': 'env SAL_ENABLE_FILE_LOCKING=1 SAL_USE_VCLPLUGIN=gtk3 /usr/lib/libreoffice/program/soffice.bin -env:URE_BOOTSTRAP=vnd.sun.star.pathname:/usr/lib/libreoffice/program/fundamentalrc -env:UserInstallation=file:///root/.perant-office --nologo --calc',
    'impress': 'env SAL_ENABLE_FILE_LOCKING=1 SAL_USE_VCLPLUGIN=gtk3 /usr/lib/libreoffice/program/soffice.bin -env:URE_BOOTSTRAP=vnd.sun.star.pathname:/usr/lib/libreoffice/program/fundamentalrc -env:UserInstallation=file:///root/.perant-office --nologo --impress',
    'editor': '/usr/bin/mousepad',
    'settings': '/usr/bin/xfce4-settings-manager',
    'apps': '/usr/bin/xfce4-appfinder',
}
names = {'files': '工作文件', 'terminal': '终端', 'editor': '文本编辑器',
         'writer': '文档', 'calc': '表格', 'impress': '演示文稿',
         'settings': '系统设置', 'apps': '全部应用'}
iconnames = {'files': 'folder', 'terminal': 'utilities-terminal', 'editor': 'text-x-generic',
             'writer': 'office-writer',
             'calc': 'office-calc', 'impress': 'office-impress',
             'settings': 'preferences-system', 'apps': 'edit-find'}

def office_launcher(command):
    # LibreOffice 25.8.7.3 exithelper.h defines 81 as NORMAL_RESTART;
    # desktop/unx/source/start.c repeats that exit with all original arguments.
    # 79 is CRASH_WITH_RESTART and has different recovery semantics: do not
    # automatically retry it, or any other error, in this compatibility launcher.
    return f'''#!/bin/sh
cd /workspace || exit 1
perant_office_launch=1
while :; do
    if {command} "$@"; then
        exit 0
    else
        perant_office_status=$?
    fi
    if [ "$perant_office_status" -ne 81 ]; then
        exit "$perant_office_status"
    fi
    if [ "$perant_office_launch" -ge 3 ]; then
        printf '%s\\n' 'PerAnt: LibreOffice still requested a normal restart after three launches; stopping.' >&2
        exit 81
    fi
    perant_office_launch=$((perant_office_launch + 1))
    printf '%s\\n' 'PerAnt: LibreOffice requested a normal restart; retrying with the same profile and arguments.' >&2
done
'''

for app, command in commands.items():
    launcher = base / ('launch-' + app)
    put(launcher, office_launcher(command) if app in ('writer', 'calc', 'impress')
        else '#!/bin/sh\ncd /workspace || exit 1\nexec ' + command + ' "$@"\n')
    launcher.chmod(0o700)
    desktop = '[Desktop Entry]\nType=Application\nName=' + names[app] + '\n'
    argument = ' %U' if app in ('writer', 'calc', 'impress') else ''
    desktop += f'Exec={launcher}{argument}\nIcon={icons / (iconnames[app] + ".xpm")}\n'
    desktop += 'Terminal=false\nStartupNotify=false\nCategories=PerAnt;\n'
    targets = [data / 'applications' / ('perant-' + app + '.desktop')]
    if app in ('files', 'writer', 'terminal', 'settings'):
        targets.append(base / 'Desktop' / ('perant-' + app + '.desktop'))
    for target in targets:
        put(target, desktop)
        target.chmod(0o700)

# The official session manager starts the five standard Failsafe clients.
# XDG overrides suppress hardware/autostart helpers unavailable on Android.
for vendor in Path('/etc/xdg/autostart').glob('*.desktop'):
    put(config / 'autostart' / vendor.name, '[Desktop Entry]\nType=Application\nHidden=true\n')
channels = config / 'xfce4/xfconf/xfce-perchannel-xml'
channels.mkdir(parents=True, exist_ok=True)

def channel(name):
    return ET.Element('channel', name=name, version='1.0')

def value_type(value):
    if isinstance(value, bool): return 'bool', str(value).lower()
    if isinstance(value, int): return 'int', str(value)
    if isinstance(value, float): return 'double', str(value)
    return 'string', str(value)

def prop(parent, path, value=None, kind=None):
    parts = path.strip('/').split('/')
    for name in parts[:-1]:
        node = next((p for p in parent if p.get('name') == name), None)
        if node is None: node = ET.SubElement(parent, 'property', name=name, type='empty')
        parent = node
    name = parts[-1]
    old = next((p for p in parent if p.get('name') == name), None)
    if old is not None: parent.remove(old)
    if isinstance(value, list):
        node = ET.SubElement(parent, 'property', name=name, type='array')
        for item in value:
            typ, text = value_type(item)
            ET.SubElement(node, 'value', type=typ, value=text)
    else:
        typ, text = value_type(value)
        node = ET.SubElement(parent, 'property', name=name, type=kind or ('empty' if value is None else typ))
        if value is not None: node.set('value', text)
    return node

def save(root):
    ET.ElementTree(root).write(channels / (root.get('name') + '.xml'), encoding='utf-8', xml_declaration=True)

session = ET.parse('/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml').getroot()
for path, value in [('general/SaveOnExit', False), ('general/PromptOnLogout', False),
                    ('general/StartAssistiveTechnologies', False), ('general/DisableTcp', True),
                    ('compat/LaunchGNOME', False), ('compat/LaunchKDE', False),
                    ('startup/ssh-agent/enabled', False), ('startup/gpg-agent/enabled', False)]:
    prop(session, path, value)
prop(session, 'sessions/Failsafe/Client0_Command', ['/usr/bin/xfwm4', '--compositor=off'])
save(session)

settings = ET.parse('/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xsettings.xml').getroot()
for path, value in [('Net/ThemeName', 'Adwaita'), ('Net/IconThemeName', 'PerAnt'),
                    ('Gtk/FontName', 'DejaVu Sans 18'), ('Gtk/MonospaceFontName', 'DejaVu Sans Mono 18'),
                    ('Gtk/EnableAnimations', False), ('Gtk/DialogsUseHeader', False),
                    ('Gtk/MenuImages', True), ('Gtk/ButtonImages', True),
                    ('Net/EnableEventSounds', False)]:
    prop(settings, path, value)
save(settings)

# Original flat Xfwm theme: real 80px window controls, no compositor or blur.
# All required frame pixmaps are XPM and use the same trusted loader as icons.
theme = data / 'themes/PerAnt/xfwm4'
def frame_xpm(name, pixels, colors):
    rows = ['"%s c %s",' % (key, color) for key, color in colors.items()]
    rows += ['"' + ''.join(row) + '",' for row in pixels]
    put(theme / (name + '.xpm'), '/* XPM */\n/* PerAnt; GPL-3.0-only */\n'
        'static char *frame[] = {\n"%d %d %d 1",\n' % (len(pixels[0]), len(pixels), len(colors))
        + '\n'.join(rows).rstrip(',') + '\n};\n')
for state in ('active', 'inactive'):
    color = '#ffffff' if state == 'active' else '#f1f5f9'
    for number in range(1, 6):
        frame_xpm('title-' + str(number) + '-' + state, [['b'] for _ in range(80)], {'b': color})
    for name, w, h in [('top-left', 4, 80), ('top-right', 4, 80), ('left', 4, 1),
                       ('right', 4, 1), ('bottom', 1, 4), ('bottom-left', 4, 4), ('bottom-right', 4, 4)]:
        frame_xpm(name + '-' + state, [['b'] * w for _ in range(h)], {'b': '#cbd5e1'})
for button in ('close', 'hide', 'maximize', 'maximize-toggled', 'menu',
               'shade', 'shade-toggled', 'stick', 'stick-toggled'):
    for state in ('active', 'inactive', 'prelight', 'pressed'):
        bg = {'active': '#ffffff', 'inactive': '#f1f5f9', 'prelight': '#dbeafe', 'pressed': '#bfdbfe'}[state]
        fg = '#64748b' if state == 'inactive' else '#334155'
        pixels = [['b'] * 80 for _ in range(80)]
        def dot(x, y):
            for py in range(y-1, y+2):
                for px in range(x-1, x+2): pixels[py][px] = 'f'
        def stroke(x0, y0, x1, y1):
            n = max(abs(x1-x0), abs(y1-y0), 1)
            for i in range(n+1): dot(round(x0+(x1-x0)*i/n), round(y0+(y1-y0)*i/n))
        if button == 'close':
            stroke(29, 29, 51, 51); stroke(29, 51, 51, 29)
        elif button == 'hide': stroke(28, 47, 52, 47)
        elif button.startswith('maximize'):
            for x0, y0, x1, y1 in [(28, 29, 52, 29), (28, 29, 28, 51),
                                   (28, 51, 52, 51), (52, 29, 52, 51)]: stroke(x0, y0, x1, y1)
        else:
            for y in (31, 40, 49): stroke(28, y, 52, y)
        frame_xpm(button + '-' + state, pixels, {'b': bg, 'f': fg})
put(theme / 'themerc', 'active_text_color=#1e293b\ninactive_text_color=#64748b\n'
    'button_offset=0\nbutton_spacing=0\nfull_width_title=true\nframe_border_top=0\n'
    'show_app_icon=false\ntitle_horizontal_offset=16\ntitle_vertical_offset_active=0\n'
    'title_vertical_offset_inactive=0\ntitle_shadow_active=false\ntitle_shadow_inactive=false\n')

wm = channel('xfwm4')
for path, value in [('general/use_compositing', False), ('general/theme', 'PerAnt'),
                    ('general/title_font', 'DejaVu Sans Bold 18'), ('general/button_layout', 'O|HMC'),
                    ('general/workspace_count', 1), ('general/wrap_workspaces', False),
                    ('general/cycle_workspaces', False), ('general/show_dock_shadow', False),
                    ('general/show_frame_shadow', False), ('general/show_popup_shadow', False)]:
    prop(wm, path, value)
save(wm)

shortcuts = ET.parse('/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-keyboard-shortcuts.xml').getroot()
from copy import deepcopy
for provider in ('commands', 'xfwm4'):
    group = next(p for p in shortcuts if p.get('name') == provider)
    defaults = next(p for p in group if p.get('name') == 'default')
    previous = next((p for p in group if p.get('name') == 'custom'), None)
    if previous is not None: group.remove(previous)
    custom = deepcopy(defaults)
    custom.set('name', 'custom')
    group.append(custom)
    prop(custom, 'override', True)
for key, command in {'<Primary><Alt>t': str(base / 'launch-terminal'),
                     '<Super>e': str(base / 'launch-files'), '<Super>n': str(base / 'launch-editor'),
                     '<Super>w': str(base / 'launch-writer'),
                     '<Super>c': str(base / 'launch-calc'), '<Super>p': str(base / 'launch-impress'),
                     '<Super>i': str(base / 'launch-settings'),
                     '<Super>space': '/usr/bin/xfce4-popup-applicationsmenu'}.items():
    prop(shortcuts, 'commands/custom/' + key, command)
for key, command in {'<Super>d': 'show_desktop_key', '<Alt>Tab': 'cycle_windows_key',
                     '<Alt>F10': 'maximize_window_key'}.items():
    # Xfwm selects the FIRST shortcut for an action, unlike command providers.
    # Remove the old action binding (e.g. Ctrl+Alt+d), then install its new key.
    custom = next(p for p in next(p for p in shortcuts if p.get('name') == 'xfwm4')
                  if p.get('name') == 'custom')
    for previous in list(custom):
        if previous.get('value') == command:
            custom.remove(previous)
    prop(shortcuts, 'xfwm4/custom/' + key, command)
save(shortcuts)

files = channel('thunar')
for path, value in [('misc-single-click', True), ('misc-single-click-timeout', 0),
                    ('misc-volume-management', False), ('misc-thumbnail-mode', 'THUNAR_THUMBNAIL_MODE_NEVER'),
                    ('last-icon-view-zoom-level', 'THUNAR_ZOOM_LEVEL_100_PERCENT'),
                    ('last-window-width', width), ('last-window-height', max(height-84, 256)),
                    ('last-window-maximized', True), ('last-show-hidden', False)]:
    prop(files, path, value)
save(files)

desktop = channel('xfce4-desktop')
for path, value in [('desktop-icons/style', 2), ('desktop-icons/icon-size', 80),
                    ('desktop-icons/use-custom-font-size', True), ('desktop-icons/font-size', 18.0),
                    ('desktop-icons/single-click', True), ('desktop-icons/show-thumbnails', False),
                    ('desktop-icons/use-custom-label-text-color', True),
                    ('desktop-icons/label-text-color', [0.118, 0.161, 0.231, 1.0]),
                    ('desktop-icons/file-icons/show-home', False), ('desktop-icons/file-icons/show-trash', False),
                    ('desktop-icons/file-icons/show-filesystem', False),
                    ('desktop-icons/file-icons/show-network-removable', False),
                    ('desktop-icons/file-icons/show-device-removable', False),
                    ('desktop-icons/file-icons/show-device-fixed', False),
                    ('desktop-icons/file-icons/show-unknown-removable', False),
                    ('backdrop/single-workspace-mode', True), ('backdrop/single-workspace-number', 0)]:
    prop(desktop, path, value)
# Xvnc's RandR monitor connector is VNC-0. Legacy monitor0 is retained as fallback.
for monitor in ('monitorVNC-0', 'monitor0'):
    prefix = 'backdrop/screen0/' + monitor + '/workspace0/'
    prop(desktop, prefix + 'color-style', 0)
    prop(desktop, prefix + 'image-style', 0)
    prop(desktop, prefix + 'rgba1', [0.914, 0.933, 0.961, 1.0])
save(desktop)

panel = channel('xfce4-panel')
prop(panel, 'configver', 2)
panels = prop(panel, 'panels', [1])
prop(panels, 'dark-mode', False)
for path, value, kind in [('position', 'p=10;x=0;y=0', None), ('position-locked', True, None),
                           ('length', 100, 'uint'), ('length-adjust', False, None),
                           ('size', 84, 'uint'), ('icon-size', 64, 'uint'),
                           ('autohide-behavior', 0, 'uint'), ('nrows', 1, 'uint')]:
    prop(panels, 'panel-1/' + path, value, kind)
prop(panels, 'panel-1/plugin-ids', [1, 2, 3, 4, 5, 6, 7])
plugins = prop(panel, 'plugins')
for number, plugin in [(1, 'applicationsmenu'), (2, 'launcher'), (3, 'launcher'),
                       (4, 'launcher'), (5, 'tasklist'), (6, 'clock'), (7, 'showdesktop')]:
    prop(plugins, 'plugin-' + str(number), plugin)
for path, value in [('show-button-title', False), ('show-menu-icons', True),
                    ('button-icon', str(icons / 'perant-start.xpm')),
                    ('custom-menu', True), ('custom-menu-file', str(base / 'applications.menu'))]:
    prop(plugins, 'plugin-1/' + path, value)
for number, app in [(2, 'files'), (3, 'terminal'), (4, 'writer')]:
    filename = 'perant-' + app + '.desktop'
    put(config / ('xfce4/panel/launcher-' + str(number)) / filename,
        (data / 'applications' / filename).read_text())
    prop(plugins, 'plugin-' + str(number) + '/items', [filename])
for path, value in [('show-labels', False), ('show-only-minimized', False),
                    ('show-handle', False), ('flat-buttons', False), ('grouping', 1),
                    ('include-all-workspaces', False)]:
    prop(plugins, 'plugin-5/' + path, value)
prop(plugins, 'plugin-6/mode', 2, 'uint')
prop(plugins, 'plugin-6/digital-format', '%H:%M')
save(panel)

# A normal freedesktop applications menu rendered by Xfce's actual menu plugin.
menu = ET.Element('Menu')
ET.SubElement(menu, 'Name').text = 'PerAnt'
ET.SubElement(menu, 'AppDir').text = str(data / 'applications')
ET.SubElement(menu, 'DefaultAppDirs')
included = ET.SubElement(menu, 'Include')
layout = ET.SubElement(menu, 'Layout')
for app in ('files', 'writer', 'calc', 'impress', 'terminal', 'editor', 'settings', 'apps'):
    filename = 'perant-' + app + '.desktop'
    ET.SubElement(included, 'Filename').text = filename
    ET.SubElement(layout, 'Filename').text = filename
ET.ElementTree(menu).write(base / 'applications.menu', encoding='utf-8', xml_declaration=True)
put(config / 'xfce4/terminal/terminalrc', '[Configuration]\nFontName=DejaVu Sans Mono 18\n'
    'FontUseSystem=FALSE\nMiscMenubarDefault=TRUE\nMiscToolbarDefault=FALSE\n'
    'MiscBell=FALSE\nBackgroundMode=TERMINAL_BACKGROUND_SOLID\n'
    'ColorBackground=#151b26\nColorForeground=#e2e8f0\nScrollingLines=3000\n')
put(config / 'xfce4/helpers.rc', 'TerminalEmulator=xfce4-terminal\nFileManager=Thunar\n')
put(config / 'mimeapps.list', '[Default Applications]\n'
    'application/vnd.oasis.opendocument.text=perant-writer.desktop;\n'
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document=perant-writer.desktop;\n'
    'application/msword=perant-writer.desktop;\n'
    'application/vnd.oasis.opendocument.spreadsheet=perant-calc.desktop;\n'
    'application/vnd.ms-excel=perant-calc.desktop;\n'
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet=perant-calc.desktop;\n'
    'text/csv=perant-calc.desktop;\n'
    'application/vnd.oasis.opendocument.presentation=perant-impress.desktop;\n'
    'application/vnd.ms-powerpoint=perant-impress.desktop;\n'
    'application/vnd.openxmlformats-officedocument.presentationml.presentation=perant-impress.desktop;\n'
    'text/plain=org.xfce.mousepad.desktop;\ntext/markdown=org.xfce.mousepad.desktop;\n')

# Office preferences persist across sessions, unlike display caches.
office = Path('/root/.perant-office')
office.mkdir(mode=0o700, exist_ok=True)
registry = office / 'user/registrymodifications.xcu'
if not registry.exists():
    # The pinned official Paths schema names Work/WritePath as the save folder.
    # Set only that initial path; retain recovery and format/security warnings.
    put(registry, '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<oor:items xmlns:oor="http://openoffice.org/2001/registry">'
        '<item oor:path="/org.openoffice.Office.Paths/Paths/'
        'org.openoffice.Office.Paths:NamedPath[\'Work\']">'
        '<prop oor:name="WritePath" oor:op="fuse"><value>file:///workspace</value>'
        '</prop></item></oor:items>\n')
# Keyfile GSettings keeps editor preferences session-local without another daemon.
put(config / 'glib-2.0/settings/keyfile', '[org/xfce/mousepad/preferences/view]\n'
    'font-name=\'DejaVu Sans Mono 18\'\nuse-default-monospace-font=false\n'
    '\n[org/xfce/mousepad/state/window]\nmaximized=true\n')
PY

vnc_pid=
session_pid=
bus_pid=
cleanup() {
    trap - EXIT INT TERM HUP
    rm -f /run/perant-desktop/desktop.ready /run/perant-desktop/desktop.ready.part
    for process in "$session_pid" "$bus_pid" "$vnc_pid"; do
        [ -z "$process" ] || kill "$process" 2>/dev/null || :
    done
    wait 2>/dev/null || :
}
trap cleanup EXIT
trap 'exit 143' INT TERM HUP
/usr/bin/Xvnc "$DISPLAY" -geometry "${width}x${height}" -depth 24 \
    -rfbport -1 -rfbunixpath /run/perant-desktop/rfb.sock -rfbunixmode 384 \
    -SecurityTypes None -AlwaysShared=1 -AcceptSetDesktopSize=0 \
    -nolisten tcp -auth "$XAUTHORITY" -extension MIT-SHM -extension GLX &
vnc_pid=$!
count=0
while [ ! -S "/tmp/.X11-unix/X$display" ]; do
    kill -0 "$vnc_pid" 2>/dev/null || { wait "$vnc_pid"; exit 70; }
    count=$((count + 1))
    [ "$count" -le 150 ] || exit 71
    sleep 0.1
done
# A private session bus only. No system daemon, network service or Android root.
/usr/bin/dbus-daemon --session --nofork --address="$DBUS_SESSION_BUS_ADDRESS" &
bus_pid=$!
cd /workspace
/usr/bin/xfce4-session &
session_pid=$!
# The real Xfce session manager owns the standard Failsafe clients. Wait for
# mapped panel/desktop windows and the live WM's EWMH desktop property.
count=0
while :; do
    for process in "$vnc_pid" "$session_pid" "$bus_pid"; do
        kill -0 "$process" 2>/dev/null || exit 72
    done
    panel_pid=$(pidof xfce4-panel 2>/dev/null || :)
    desktop_pid=$(pidof xfdesktop 2>/dev/null || :)
    wm_pid=$(pidof xfwm4 2>/dev/null || :)
    if /usr/bin/xdotool get_desktop >/dev/null 2>&1 \
        && [ -n "$wm_pid" ] && [ -n "$panel_pid" ] && [ -n "$desktop_pid" ] \
        && /usr/bin/xdotool search --onlyvisible --pid "$panel_pid" >/dev/null 2>&1 \
        && /usr/bin/xdotool search --onlyvisible --pid "$desktop_pid" >/dev/null 2>&1; then
        break
    fi
    count=$((count + 1))
    [ "$count" -le 250 ] || exit 73
    sleep 0.1
done
printf 'perant-desktop-v6\n' > /run/perant-desktop/desktop.ready.part
mv /run/perant-desktop/desktop.ready.part /run/perant-desktop/desktop.ready
printf 'PERANT_DESKTOP_READY display=%s geometry=%sx%s transport=private-unix shell=Xfce-4.20\n' "$DISPLAY" "$width" "$height"
wait "$session_pid"
