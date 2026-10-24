# CUA planner tools

The tool set depends on the runtime and model adapter. These are registered
planner tools, not every capability implemented inside the underlying driver.
The runtime still validates targets, permissions and arguments before execution.

## trycua background comparison

`ComputerUseReferenceRuntime.definitions` intersects its allowlist with the
selected driver's advertised schemas. The patched 0.36.0 catalog exposes:

| Purpose | Tools |
| --- | --- |
| Discover apps/windows | `list_apps`, `list_windows`, `launch_app` |
| Observe/verify | `get_window_state`, `get_accessibility_tree`, `verify_state`, `check_permissions` |
| Pointer actions | `click`, `double_click`, `right_click`, `drag`, `move_cursor` |
| Text and scrolling | `type_text`, `set_value`, `scroll`, `zoom` |
| Cursor/display information | `get_cursor_position`, `get_screen_size`, `get_agent_cursor_state` |
| Finish | `finish`, `fail` |

The first 19 tools come from the driver; `finish` and `fail` are added by Muesli.
`get_window_state` carries the screenshot; there is no separate screenshot tool
in this planner catalog. Generic key/menu dispatch is deliberately excluded
because PID-directed delivery alone did not prevent Chrome activation.

When browser integration is enabled, six additional tools are exposed:
`get_browser_state`, `browser_navigate`, `browser_click`, `browser_type`,
`browser_dialog`, `browser_pointer`. All six are excluded with
`--trycua-accessibility-only`. Driver-internal setup/session tools are not planner
capabilities. There is no arbitrary shell, AppleScript or JavaScript execution tool.

## Native Swift desktop runtime

Hosted planners receive the definitions in `ComputerUseToolRegistry`:

| Purpose | Tools |
| --- | --- |
| Discover/observe | `list_apps`, `launch_app`, `list_windows`, `get_app_state`, `get_window_state` |
| Pointer/AX actions | `move_cursor`, `click_element`, `click_point`, `perform_secondary_action`, `scroll`, `drag` |
| Text/keyboard | `edit_text`, `set_value`, `type_text`, `paste_text`, `press_key`, `hotkey` |
| Browser | `list_browser_tabs`, `activate_browser_tab`, `open_new_browser_tab`, `navigate_url`, `navigate_active_browser_tab`, `page_get_text`, `page_query_dom` |
| Finish | `finish`, `fail` |

`edit_text` invokes the shared Quill writing capability against an observed
editable field. Browser text/DOM reads use constrained read-only Apple Events
JavaScript. These are not arbitrary script-execution permissions. Native tools
can activate apps; this catalog is not a strict-background guarantee.

The on-device adapter currently keeps only:
`list_apps`, `launch_app`, `list_windows`, `get_app_state`, `get_window_state`,
`move_cursor`, `click_element`, `edit_text`, `set_value`, `type_text`, `paste_text`,
`press_key`, `hotkey`, `scroll`, `finish`, `fail`.
Its generation API consumes text, not the screenshot image. Coordinate clicking,
dragging and browser accelerators are excluded from this native on-device set.

## Muesli settings phase

Settings planning has a separate catalog:
`inspect_muesli_setting`, `ask_user_question`, `set_muesli_setting`,
`configure_muesli_setting`, `settings_manual_only`, `continue_desktop_task`,
`settings_unavailable`.

Detailed choices are fetched only for the relevant setting. Prompt modifications
remain manual-only. These tools are not automatically appended to the trycua
comparison's desktop catalog.

## Sources of truth

- `ComputerUseReferenceRuntime.swift`: trycua allowlist and background restrictions.
- `ComputerUseToolRegistry.swift`: native schemas and descriptions.
- `ComputerUseLocalPlanner.swift`: on-device filtering.
- `ComputerUseSettings.swift`: settings planning tools.

Update this inventory when these catalogs change. A tool name alone does not
imply identical arguments or behavior across runtimes.
