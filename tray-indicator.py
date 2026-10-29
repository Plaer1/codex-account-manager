#!/usr/bin/python3
"""KDE/Wayland tray menu. The desktop anchors the exported native menu."""
import json
import os
import sys
from datetime import datetime
from pathlib import Path
import gi

gi.require_version('Gtk', '3.0')
try:
    gi.require_version('AyatanaAppIndicator3', '0.1')
    from gi.repository import AyatanaAppIndicator3 as Indicator
except (ValueError, ImportError):
    gi.require_version('AppIndicator3', '0.1')
    from gi.repository import AppIndicator3 as Indicator
from gi.repository import GLib, Gtk

GLib.set_application_name('Codex Account Manager')
icon = Path(sys.argv[1]).resolve()
indicator = Indicator.Indicator.new(os.environ.get('CODEX_MANAGER_TRAY_ID', 'codex-account-manager'), str(icon), Indicator.IndicatorCategory.APPLICATION_STATUS)
indicator.set_title('Codex Account Manager')
indicator.set_icon_theme_path(str(icon.parent))
indicator.set_icon_full(str(icon), 'Codex Account Manager')
indicator.set_status(Indicator.IndicatorStatus.ACTIVE)
menu = None
buffer = b''

def emit(action, profile=None):
    value = {'action': action}
    if profile is not None: value['profile'] = profile
    print(json.dumps(value, ensure_ascii=True), flush=True)

def add_item(parent, label, action=None, sensitive=True):
    item = Gtk.MenuItem(label=label); item.set_sensitive(sensitive)
    if action is not None: item.connect('activate', lambda _item: emit(*action))
    parent.append(item)
    return item

def time_text(value):
    try: return datetime.fromtimestamp(value).strftime('%b %d %H:%M')
    except (TypeError, ValueError, OverflowError, OSError): return 'unknown'

def update(state):
    global menu
    menu = Gtk.Menu()
    add_item(menu, 'Codex Accounts', sensitive=False)
    add_item(menu, 'Open Manager', ('open',))
    add_item(menu, 'Refresh usage', ('refresh',))
    profiles = state.get('profiles', [])
    if profiles: menu.append(Gtk.SeparatorMenuItem())
    for profile in profiles:
        name = profile.get('name', '')
        display = profile.get('display') or name
        windows = profile.get('windows') or []
        summary = '  ·  '.join(('7d' if w.get('seconds', 0) >= 86400 else '5h') + ': ' + str(round(w.get('left', 0))) + '%' for w in windows)
        label = ('✓ ' if profile.get('active') else '') + display + ('   ' + summary if summary else '')
        item = add_item(menu, label)
        submenu = Gtk.Menu(); item.set_submenu(submenu)
        if profile.get('stale'): add_item(submenu, 'Recorded usage', sensitive=False)
        if not windows: add_item(submenu, profile.get('error') or 'Usage unavailable', sensitive=False)
        for window in windows:
            period = '7-day' if window.get('seconds', 0) >= 86400 else '5-hour'
            label = f"{period}: {window.get('left', 0):.0f}% remaining · resets {time_text(window.get('reset'))}"
            add_item(submenu, label, sensitive=False)
        submenu.append(Gtk.SeparatorMenuItem())
        add_item(submenu, 'Already active' if profile.get('active') else 'Make active', ('activate', name), sensitive=not profile.get('active') and profile.get('valid', True))
    menu.append(Gtk.SeparatorMenuItem())
    add_item(menu, 'Add account…', ('add',))
    add_item(menu, 'Capture current account…', ('capture',))
    add_item(menu, 'Quit', ('quit',))
    menu.show_all(); indicator.set_menu(menu)

def on_input(_source, condition):
    global buffer
    if condition & GLib.IO_IN:
        try: chunk = os.read(sys.stdin.fileno(), 65536)
        except BlockingIOError: chunk = b''
        if chunk:
            buffer += chunk
            while b'\n' in buffer:
                line, buffer = buffer.split(b'\n', 1)
                try: message = json.loads(line)
                except (ValueError, UnicodeError): continue
                if message.get('type') == 'shutdown': Gtk.main_quit(); return False
                if message.get('type') == 'state': update(message)
    if condition & (GLib.IO_HUP | GLib.IO_ERR): Gtk.main_quit(); return False
    return True

update({'profiles': []})
os.set_blocking(sys.stdin.fileno(), False)
GLib.io_add_watch(sys.stdin.fileno(), GLib.IO_IN | GLib.IO_HUP | GLib.IO_ERR, on_input)
emit('ready')
Gtk.main()
