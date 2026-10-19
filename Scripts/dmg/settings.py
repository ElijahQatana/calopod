# dmgbuild settings for the Calopod installer. Scripts/make-calopod-dmg.sh passes
#   -D app=<Calopod.app> -D background=<background.png> -D hint=<text file> [-D icon=<icns>]
# The numbers match Scripts/dmg/make-background.swift: the arrow runs between the two icon
# centers and the window is the size of the background.
import os

app = defines["app"]  # noqa: F821 - dmgbuild injects `defines`
app_name = os.path.basename(app)
hint = defines["hint"]  # noqa: F821
hint_name = os.path.basename(hint)

format = "UDZO"
files = [app, hint]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821
icon = defines.get("icon")  # noqa: F821

window_rect = ((200, 120), (660, 440))
default_view = "icon-view"
icon_size = 112
text_size = 13
icon_locations = {
    app_name: (180, 165),
    "Applications": (480, 165),
    hint_name: (330, 350),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
