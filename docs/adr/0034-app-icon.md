# ADR-0034: The app icon: an AI-generated quail, rendered to the macOS icon shape by a script

**Date:** 2026-09-24 · **Status:** Accepted

**Decision:** The icon is a flying California quail on a yellow field, generated with ChatGPT's image tool from the maintainer's prompt and kept as `Design/AppIcon-source.png` (1254 px, flat colour). `Design/make-icon.py` (Python + Pillow) turns it into the ten `AppIcon.appiconset` sizes: a 824 px superellipse ("squircle") on the 1024 px canvas with the standard soft shadow, because a plain `.appiconset` isn't masked by the system. Re-run it after changing the source; the PNGs are committed so a build needs neither Python nor Pillow.
**Provenance:** the image is AI-generated. Its copyright status is uncertain in most jurisdictions (purely machine-generated images may not be protected at all), and the generator's terms, not this repo's, decide what can be done with it. It sits under `Design/` and the asset catalog, apart from the MIT-licensed code, so it can be swapped for commissioned artwork without touching anything else.
**Not done:** the menu-bar glyph is still an SF Symbol per state (stopped/starting/running/failed); a quail silhouette template image would need to read at 18 pt in both appearances and is separate work. No dark or tinted icon variants (macOS 26's Icon Composer `.icon` format would give layered artwork; the flat raster is the portable baseline).
**Alternatives:** A hand-drawn vector quail (more control, more time); a lettermark.
**Revisit if:** Quail gets commissioned artwork, or the Store submission wants an `.icon` file.
