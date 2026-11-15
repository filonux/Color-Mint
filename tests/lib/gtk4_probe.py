#!/usr/bin/env python3
"""Draws one libadwaita suggested-action button and prints what GTK 4 really painted.

tests/test_gui_render.sh runs it once per case, each in a fresh process with its own ~/.config/gtk-4.0: GTK reads
that user stylesheet once per process, so a case cannot reuse another one.

Usage:  gtk4_probe.py --check              exit 0 when GTK 4.10+ and libadwaita load (nothing is drawn)
        gtk4_probe.py [--dark] [NAME ...]  needs DISPLAY; --dark forces the dark colour scheme
Output: one `name=value` line per item: `pixel=#rrggbb` (the button's background, read from the rendered texture)
        and `NAME=#rrggbb` for each named colour asked for (`NAME=none` when no stylesheet defines it).
Exit:   0 ok, 2 GTK 4 or libadwaita unavailable, 3 nothing was drawn in 10 s.
"""
import sys

try:
    import gi
    gi.require_version('Gtk', '4.0')
    gi.require_version('Adw', '1')
    from gi.repository import Adw, Gdk, GLib, Gtk
    if not hasattr(Gdk, 'TextureDownloader'):      # GTK < 4.10 cannot hand the pixels back
        raise ImportError('GTK 4.10 or newer is needed to read the rendered pixels')
except (ImportError, ValueError) as exc:
    sys.stderr.write('gtk4_probe: %s\n' % exc)
    sys.exit(2)

TIMEOUT_MS = 10000


def hexcolor(rgba):
    return '#%02x%02x%02x' % tuple(round(c * 255) for c in (rgba.red, rgba.green, rgba.blue))


def main(args):
    if '--check' in args:
        return 0
    names = [a for a in args if not a.startswith('--')]
    Gtk.init()
    Adw.init()
    if '--dark' in args:
        Adw.StyleManager.get_default().set_color_scheme(Adw.ColorScheme.FORCE_DARK)

    window = Gtk.Window(default_width=240, default_height=80)
    button = Gtk.Button(label='Accent')
    button.add_css_class('suggested-action')
    window.set_child(button)
    window.present()

    loop = GLib.MainLoop()
    result = {'status': 3}

    def measure():
        # Wait for the first layout: by then every user and libadwaita stylesheet is resolved.
        width, height = button.get_width(), button.get_height()
        if width <= 0 or height <= 0:
            return True
        snapshot = Gtk.Snapshot()
        Gtk.WidgetPaintable.new(button).snapshot(snapshot, width, height)
        node = snapshot.to_node()
        if node is None:
            return True
        texture = window.get_native().get_renderer().render_texture(node, None)
        downloader = Gdk.TextureDownloader.new(texture)
        downloader.set_format(Gdk.MemoryFormat.R8G8B8A8)
        data, stride = downloader.download_bytes()
        raw = data.get_data()
        index = (height // 2) * stride + 8 * 4          # 8 px in from the left edge: clear of the label and the corner
        print('pixel=#%02x%02x%02x' % tuple(raw[index:index + 3]))
        context = button.get_style_context()
        for name in names:
            found, rgba = context.lookup_color(name)
            print('%s=%s' % (name, hexcolor(rgba) if found else 'none'))
        result['status'] = 0
        loop.quit()
        return False

    def give_up():
        loop.quit()
        return False

    GLib.timeout_add(50, measure)
    GLib.timeout_add(TIMEOUT_MS, give_up)
    loop.run()
    return result['status']


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
