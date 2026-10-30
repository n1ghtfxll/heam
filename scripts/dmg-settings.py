# dmgbuild layout for heam's installer window. Used by ./build.sh --dmg.
# Coordinates match scripts/make-dmg-background.swift (points, top-left origin, icon centers).
import os.path

app = defines.get("app", "build/heam.app")  # noqa: F821 (dmgbuild provides `defines`)
app_name = os.path.basename(app)

format = "ULFO"  # LZFSE-compressed, read-only
files = [app]
symlinks = {"Applications": "/Applications"}
icon = "Resources/AppIcon.icns"  # the mounted volume's icon

background = "Resources/dmg-background.tiff"
window_rect = ((200, 120), (660, 400))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
show_icon_preview = False

icon_size = 112
text_size = 13
icon_locations = {
    app_name: (190, 196),
    "Applications": (470, 196),
}
