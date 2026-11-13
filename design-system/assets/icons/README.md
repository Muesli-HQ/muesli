# Sidebar icon specimens

The PNG previews are generated locally on macOS from SF Symbols using the medium
weight system configuration. From the repository root, run:

```sh
swift design-system/scripts/render-sidebar-symbols.swift
```

The generated PNGs are ignored by Git. They depict the symbols named in
`SidebarOrder.swift` and `SidebarView.swift`, including both Meetings states.
The application uses native SF Symbols, not these preview images. Without the
local PNGs, the symbol names remain visible in the reference.

`time-turner.svg` follows `TimeTurnerIcon.swift`, and `vidshots.svg` follows
`VidshotIcon.swift`. Their CSS masks adopt the selected preview theme. Update
these specimens when the corresponding native icons change.
