# dmgbuild settings for the disk image; mac/packaging/make-dmg.sh passes the defines.
# Positions are points from the window's top left and match make-background.swift.
app = "MirAIe AC.app"
link = "Open Privacy & Security.inetloc"
files = [(defines["app"], app), (defines["link"], link)]
symlinks = {"Applications": "/Applications"}
hide_extensions = [app, link]
icon_locations = {app: (170, 130), "Applications": (490, 130), link: (330, 462)}
background = defines["background"]
format = "ULFO"
filesystem = "APFS"
window_rect = ((200, 120), (660, 562))
default_view = "icon-view"
icon_size = 96
text_size = 12
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
arrange_by = None
