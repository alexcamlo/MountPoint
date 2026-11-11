# dmgbuild settings; run from the repo root:
#   dmgbuild -s dmg/settings.py -D app="build/Mount Point.app" "Mount Point" MountPoint.dmg
# Icon positions must match the plates drawn by dmg/background.swift.
import os

app = defines["app"]  # noqa: F821 (injected by dmgbuild)
files = [app]
symlinks = {"Applications": "/Applications"}
format = "UDZO"
background = "dmg/background.tiff"
# Height adds ~90 pt for the tab and status bars Finder draws over the 600x420 background.
window_rect = ((200, 200), (600, 510))
show_status_bar = show_tab_view = show_toolbar = show_pathbar = show_sidebar = False
default_view = "icon-view"
icon_size = 112
text_size = 12
icon_locations = {os.path.basename(app): (150, 180), "Applications": (450, 180)}
