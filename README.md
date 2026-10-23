# Hydroneer CoopNet

Online co-op for [Hydroneer](https://store.steampowered.com/app/1106840/Hydroneer/): two players,
each on their own PC and screen, play in the host's world. Hydroneer itself only has split
screen; this mod uses its hidden second player and drives it from the friend's PC over the
internet.

**Status: early test build (0.3).** The host plays any world, new or saved; the friend joins at
any time and gets the host's world. It has bugs. Tested with Hydroneer **Steam build 23218978**. Other game versions may crash at
start.

## What works

- You see each other walk and turn, with the walk animation.
- Items stay in the same place for both: picking up, carrying, dropping and throwing.
- The starter tools of a new game (shovel, pan, bucket and so on) are the same items for both.
- Digging and dumping dirt, whoever digs. The ground matches for both, because the host's exact
  terrain edits are repeated on the friend's side.
- Water and dirt in buckets, pans and other tools.
- Tool animations, and the sounds of both players' actions: dig, dump, pickup, throw, drops.
- Items the game creates while you play (found in dirt, bought) show up for both.
- Connection through Steam's networking (lobbies and relays). Steam must be running, and the
  two players must be Steam friends. Nothing to set up on routers.
- Windows, and Linux through Proton.
- Both games check that they run the same CoopNet version.
- Late join: the friend presses F7 at the main menu; the host's game saves, the relays send the
  save through Steam (about 21 MB, SHA-256 checked), and the friend's game loads it. Terrain edits
  made after the save are repeated; items keep the host's names.

## What does not work yet

- Money, shops, buying and selling, machines, building, vehicles and quests. The two worlds drift
  apart if you use them.
- Progress is saved in the host's world only. Back up a save you care about before playing it
  in co-op: this is a test build.
- Late join is tested with two copies on one PC; not yet in a real session between two PCs.
- Linux: tool animations and sounds on the friend's side came in 0.2 and are not yet confirmed
  in a real session. Steam as a Flatpak or Snap is untested.
- How the game shows water in a bucket is not fully understood: the water fields sync, but the
  water mesh may not.

## Install (players)

1. Download `HydroneerCoop-0.3.zip` from the
   [latest release](https://github.com/Zane11332/hydroneer-coopnet/releases/latest) and unzip it
   somewhere permanent.
2. Windows: double-click `Start Hydroneer Co-op.bat` and click **Install**.
   Linux: run `bash hydroneer-coop.sh`, choose **Install**, and add the Steam launch option the
   installer prints.
3. Each time you play, the host clicks **Host**, loads a world and presses **F7** in it. The friend
   clicks **Join**, stays at the game's **main menu** and presses **F7** there.

`README.txt` in the zip has the details, troubleshooting and uninstall steps.

## How it works

- The game runs [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS), which loads the Lua mod in
  `mod/CoopNet/Scripts/main.lua`. The mod adds the game's split-screen second player on the
  host and hides the split screen.
- The friend's inputs go to the host, which plays them on the second player. The host decides
  everything: it sends back both players, items and their state, terrain edits, tool animations
  and sounds. The friend's game shows that and corrects the friend's own player.
- UE4SS Lua has no sockets, so the game and `relay/coopnet_relay.py` exchange lines through two
  files. The relay sends them through Steam (`SteamNetworkingMessages`, under Steam's free test
  app 480 "Spacewar"), using Steamworks.NET's `steam_api64.dll` / `libsteam_api.so`.
- The protocol is described at the top of `main.lua`. Each game also writes a detailed action
  log to `run/coopnet-game.log` in the package folder.

## Build the player package

Windows PowerShell, from the repository folder, with the three official downloads:

```
powershell -ExecutionPolicy Bypass -File build\build-package.ps1 -Ue4ssZip <UE4SS_v3.0.1-1181-g83330635.zip> -SteamworksZip <Steamworks.NET-Standalone_2025.164.1.zip> -PythonNupkg <python.3.12.10.nupkg>
```

The script checks each download against its pinned SHA-256 or SHA-512 and stops if one differs.
It then writes `dist/HydroneerCoop-<VERSION>/` and the zip.

| Input | Source | Hash |
|---|---|---|
| `UE4SS_v3.0.1-1181-g83330635.zip` | [RE-UE4SS experimental-latest](https://github.com/UE4SS-RE/RE-UE4SS/releases/tag/experimental-latest) | SHA-256 `b9a166a756605b21058a64cde93bcaab1a855dba3553e5c7e6ce0fa8fdfad7b9` |
| `Steamworks.NET-Standalone_2025.164.1.zip` | [Steamworks.NET 2025.164.1](https://github.com/rlabrecque/Steamworks.NET/releases/tag/2025.164.1) | SHA-256 `9412348cc404563be5a43a28347cfeda3c679ee044a14d87a507ed2d796a537d` |
| `python.3.12.10.nupkg` | [nuget.org python 3.12.10](https://www.nuget.org/packages/python/3.12.10) | SHA-512 `bbda4dcf688a94211b62d50968a91b38f305d0b8d1ecd90269f74a86f8a0a4fcebb7ca162a0753a47691eb3df0c964009bd3d8194c6fd19afae8d5fd01e1cc0f` |

## Testing

The mod is tested with two copies of the game on one Windows PC. The test copies keep their saves
in their own folder, and a hash guard checks the real save folder before and after every run.
Bots on both sides walk, carry and dig, and the run compares the host's and the friend's world:
player positions, items, ground height at every dig, mirrored pickups, animations and sounds. A
test switch renames the friend's starter items, because two copies on one PC give them identical
names and hide the mismatch two real PCs have.

The test harness, research notes and the write-up of how this was built live in
[coop-anything](https://github.com/cranebeaker/coop-anything) under `games/hydroneer/`.

## Third-party software in the release zip

The release zip includes these, each with its license in `licenses/`:

- UE4SS (RE-UE4SS) v3.0.1-1181-g83330635, MIT license.
- Steamworks.NET Standalone 2025.164.1 (`steam_api64.dll`, `libsteam_api.so`), MIT license.
  Steamworks is Valve's.
- Python 3.12.10, Python Software Foundation License.

This repository contains none of the game's files; Hydroneer and its files belong to its developer.

## License

MIT, see [LICENSE](LICENSE). The third-party software keeps its own licenses.
