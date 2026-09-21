-- configs/hypr/looking-glass.lua
--
-- Looking Glass client window rules + keybinding for Omarchy quattro's
-- Lua-based Hyprland config. Equivalent of configs/hypr/looking-glass.conf
-- (the pre-quattro `.conf` drop-in).
--
-- Install by copying to ~/.config/hypr/looking-glass.lua and adding
--     require("hypr.looking-glass")
-- to ~/.config/hypr/hyprland.lua (after the other `require("hypr.…")`
-- lines). Reload with `hyprctl reload`.
--
-- Goals:
--   * Full-screen the LG window on its own workspace with no
--     border / shadow / blur / rounding.
--   * Disable animations for the window and the (currently unused)
--     LG layer namespace so nothing adds latency.
--   * `idle_inhibit = "fullscreen"` stops Hyprland's idle watcher
--     blanking the guest during long renders.
--   * One keybinding launches LG on first press and focuses it on
--     subsequent presses (Omarchy's launch-or-focus helper follows
--     the window to workspace 9 automatically).

o.window("^looking-glass-client$", {
    workspace   = "9 silent",
    fullscreen  = true,
    no_shadow   = true,
    no_blur     = true,
    rounding    = 0,
    no_anim     = true,
    immediate   = true,
    idle_inhibit = "fullscreen",
})

-- Keep Hyprland from stealing focus into overlays while the guest has
-- grabbed input. (Applies only if the LG window ever leaves fullscreen.)
o.window({ class = "^looking-glass-client$", float = true }, { no_focus = true })

-- LG doesn't currently use a layer-shell, but declare defensively so a
-- future release can't sneak animation/blur onto us.
hl.layer_rule({
    match = { namespace = "^looking-glass-client$" },
    no_anim = true,
    animation = "none",
})

-- No keybinding shipped: Omarchy's built-in `SUPER + 9` already jumps to
-- workspace 9 where the window rule above sends the LG client. If you
-- want a launch shortcut, add it in ~/.config/hypr/bindings.lua (avoid
-- `SUPER + G`, which is Omarchy's "Toggle window grouping"):
--
--     o.bind("SUPER + CTRL + G", "Launch Looking Glass",
--            { launch = "looking-glass-client", focus = "^looking-glass-client$" })
