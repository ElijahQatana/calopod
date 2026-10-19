# dmgbuild settings for the Calopod installer. Scripts/make-calopod-dmg.sh passes
#   -D app=<Calopod.app> -D background=<background.png> -D layout=<layout.json> [-D icon=<icns>]
# Sizes and positions come from Scripts/dmg/layout.json, which Scripts/dmg/make-background.swift
# reads too, so the window, the background and the icons cannot drift apart.
import json
import os

app = defines["app"]  # noqa: F821 - dmgbuild injects `defines`
app_name = os.path.basename(app)

with open(defines["layout"]) as handle:  # noqa: F821
    layout = json.load(handle)

format = "UDZO"
files = [app]
symlinks = {"Applications": "/Applications"}
background = defines["background"]  # noqa: F821
icon = defines.get("icon")  # noqa: F821

# The window rectangle includes the title bar; the background covers the area below it.
window_rect = (
    (layout["windowX"], layout["windowY"]),
    (layout["width"], layout["height"] + layout["titleBar"]),
)
default_view = "icon-view"
icon_size = layout["iconSize"]
text_size = layout["textSize"]
icon_locations = {
    app_name: (layout["appCenterX"], layout["iconCenterY"]),
    "Applications": (layout["applicationsCenterX"], layout["iconCenterY"]),
}

show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
