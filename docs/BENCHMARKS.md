# OMNIServers resource benchmarks

Format: date | label | state|cpu%,mem,idle-wakeups/s,threads|rss. Measured by scripts/bench-idle.sh on the running app (macOS, this machine). Numbers are measurements, not estimates.

2026-11-12 | baseline-before | visible|1.3  100M+ 57+   6  |rss=49MB | minimized|0.3  99M+ 57    4  |rss=38MB
2026-11-12 | baseline-before-2 | visible|2.5  86M- 63+   4  |rss=52MB | minimized|0.0  86M 63    4  |rss=29MB
2026-11-12 | menubar-true | visible|0.3  45M- 0     6  |rss=37MB | minimized|0.3  45M+ 0     5  |rss=24MB
2026-11-12 | menubar-false | visible|0.0  50M- 5     5  |rss=79MB | minimized|0.0  50M+ 5     4  |rss=52MB
2026-11-12 | after-playit-wiring (agent off) | visible|1.2  52M- 1     12 |rss=111MB | minimized|0.0  51M- 1     5  |rss=90MB

## Notes (2026-11-12)
- A long-running instance showed 1.3-2.5% CPU visible-idle; fresh launches measure 0.0-0.3%. Re-measure a days-old instance before claiming a leak.
- Menu-bar icon costs ~0.3% CPU in this measurement (0.3% -> 0.0% with `defaults write traversar.craftpanel-Swift showMenuBarIcon -bool false`). The setting exists; no UI toggle yet.
- Playit agent: 0 processes while off. A real playitd idles at ~10 MB RSS and 0.0% CPU before sign-in (measured once, no tunnels).
- Not yet done: before/after for timer changes, active-server CPU/RAM, startup/shutdown time, energy impact. No improvement numbers are claimed.
