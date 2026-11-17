# 🤠 ClaudeWhip

A silly macOS toy for the Claude desktop app: a stick-figure cowboy who cracks a whip at Claude while you wait.

> It does **not** make Claude faster. It does make waiting more fun.

## Features

- **Stick cowboy beside Claude**: stands at the bottom of the Claude window, strolls around, twirls his whip, tips his hat, whistles and follows your cursor.
- **Watches Claude work**: when Claude is generating he paces, taps his foot and cracks the whip every few seconds ("Tap, tap, tap!"). When Claude finishes he celebrates with a lasso or a six-shooter and confetti.
- **Showdowns**: if Claude takes more than 25 seconds, a bandit walks in for a high-noon duel.
- **Grab and throw him**: drag the cowboy around the window and let go.
- **Naps**: leave him alone and he falls asleep (by a campfire after 8 pm). Click to wake him.
- **Cursor styles**: the stick cowboy or the whip can follow your cursor instead.
- **Extras**: combos, speech bubbles, tumbleweeds, a UFO, a right-click helicopter spin, skins (Leather, Neon, Gold, Rainbow), sizes and daily stats in the 🤠 menu bar item.

## Requirements

- macOS with the Claude desktop app
- Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```bash
git clone https://github.com/YOUR-USERNAME/ClaudeWhip.git
cd ClaudeWhip
swiftc -O ClaudeWhip.swift -o ClaudeWhip
./ClaudeWhip
```

Look for 🤠 in the menu bar. Click into Claude and the cowboy appears.

## Permissions

To notice when Claude is generating, ClaudeWhip reads Claude's window through the macOS Accessibility API. Allow it under
**System Settings → Privacy & Security → Accessibility** (for Terminal, or for the ClaudeWhip binary if you run it directly).
Without this permission everything else still works; he just won't know when Claude is busy.

## Controls

| Action | What happens |
| --- | --- |
| Click the cowboy | He cracks the whip |
| Drag the cowboy | He dangles from your cursor; let go to throw him |
| ⌃⌥W | Crack |
| Hold right-click (cursor styles) | Helicopter spin |
| 🤠 menu | Style, skin, size, voice, stats, quit |

## Notes

- Hiding the cursor from a background app uses an undocumented macOS setting, so a future macOS update could break that one feature.
- This is an unofficial fan project and is not affiliated with or endorsed by Anthropic.

## License

MIT, see [LICENSE](LICENSE).
