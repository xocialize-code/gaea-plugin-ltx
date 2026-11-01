import GaeaPluginKit
import LTXPlugin

// The plugin's worker: LTXPlugin's definition over GPP (GaeaPluginKit). `--manifest <path>` writes manifest.json.
await GaeaPluginMain.run(ltxPlugin)
