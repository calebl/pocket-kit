# Vendored rrweb

Session replay records and plays pages with [rrweb](https://github.com/rrweb-io/rrweb),
MIT licensed (see `LICENSE-rrweb.txt`). These files are loaded only when an app
turns replay on.

| File | Package | Source in the package |
| --- | --- | --- |
| `rrweb-record-2.1.7.min.js` | `@rrweb/record@2.1.7` | `umd/record.min.js` (global `rrwebRecord`) |
| `rrweb-player-2.1.7.min.js` | `rrweb-player@2.1.7` | `umd/rrweb-player.min.js` (global `rrwebPlayer`) |
| `../../../stylesheets/pocket_kit/vendor/rrweb-player-2.1.7.css` | `rrweb-player@2.1.7` | `dist/style.css` |

The only change is the trailing `//# sourceMappingURL=` line, removed because
the maps are not shipped. To update, `npm pack` the new versions, copy the same
files under new versioned names, and change the names in
`lib/pocket_kit/replay.rb` and `viewer/replay.html`.
