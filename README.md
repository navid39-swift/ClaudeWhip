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

## Install (the easy way)

1. Download **ClaudeWhip.zip** from the [latest release](https://github.com/navid39-swift/ClaudeWhip/releases/latest).
2. Unzip it and drag **ClaudeWhip.app** into your **Applications** folder.
3. Open it. A window appears: pick a style and press **Apply**. That's it.

**First launch:** ClaudeWhip isn't from the App Store, so macOS blocks it the first time. Go to
**System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to ClaudeWhip.

Change settings any time from 🤠 → **Settings…** in the menu bar, or just open the app again.

## Build it yourself

```bash
git clone https://github.com/navid39-swift/ClaudeWhip.git
cd ClaudeWhip
./build-app.sh          # creates build/ClaudeWhip.app
open build/ClaudeWhip.app
```

## Permissions

To notice when Claude is generating, ClaudeWhip reads Claude's window through the macOS Accessibility API. Allow it under
**System Settings → Privacy & Security → Accessibility**: turn on **ClaudeWhip** (the **Grant Access…** button in the settings window takes you there).
Without this permission everything else still works; he just won't know when Claude is busy.

## Controls

| Action | What happens |
| --- | --- |
| Click the cowboy | He cracks the whip |
| Drag the cowboy | He dangles from your cursor; let go to throw him |
| ⌃⌥W | Crack |
| Hold right-click (cursor styles) | Helicopter spin |
| 🤠 menu | Style, skin, size, stats, quit |

## Notes

- Hiding the cursor from a background app uses an undocumented macOS setting, so a future macOS update could break that one feature.
- This is an unofficial fan project and is not affiliated with or endorsed by Anthropic.

## License

MIT, see [LICENSE](LICENSE).
