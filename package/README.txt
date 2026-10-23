HYDRONEER CO-OP (CoopNet) - friend test build 0.2
==================================================

Two players, each on their own PC and screen, in the HOST's world. Early test build: expect
bugs. Tested with Hydroneer Steam build 23218978.

WHAT WORKS
  - You see each other walk and turn (with the walk animation).
  - Items stay in the same place for both of you; picking up, carrying, dropping.
  - The starter tools of a new game (shovel, pan, bucket, ...) are the same items for both.
  - Digging and dumping dirt with a shovel, whoever digs: the ground matches for both.
  - Water and dirt in buckets, pans and other tools.
  - Tool animations and the sounds of both players' actions (dig, dump, pickup, throw, drops).
  - Items the game creates while you play show up for both.
  - Both games check that they run the same CoopNet version; the window says so if not.

WHAT DOES NOT WORK YET (the worlds will drift apart if you use these)
  - Money, shops, buying and selling, machines, building, vehicles, quests.
  - Saves: play in a NEW, throwaway world. Do not load your real save for co-op.
  - Joining a game that is already running: both of you start a NEW game at the same time.

YOU BOTH NEED
  - Hydroneer from Steam, the same version, and Steam running and logged in.
  - Each other on your Steam friends list.
  - Windows (64-bit): no other installs, Python is included in this folder.
  - Linux: Hydroneer through Steam's Proton, and python3 (most Linux systems have it).
    See "LINUX" below; the steps are the same with .sh scripts instead of .bat files.

THE EASY WAY: ONE LAUNCHER
  Windows: double-click "Start Hydroneer Co-op.bat". A window opens with Install, Uninstall, Host,
           Join, Stop, Open logs and Read me, and shows the connection's messages. Keep the window
           open while you play.
  Linux:   run   bash hydroneer-coop.sh   (a small window if your desktop has zenity, otherwise a
           menu in the terminal).
  The steps below are the same; the launcher just has a button for each. The separate .bat / .sh
  files still work if you prefer them.

ONE-TIME SETUP (both players)
  1. Unzip this folder somewhere permanent (for example Documents\HydroneerCoop).
     Do not move it after installing.
  2. Close Hydroneer. Double-click Install.bat. It finds Hydroneer through Steam, backs up your
     saves into this folder's "backups", and adds two things to the game folder: dwmapi.dll and
     a "ue4ss" folder. If you already use another mod that adds dwmapi.dll, it stops and changes
     nothing.

EACH TIME YOU PLAY
  HOST:
    1. Double-click Host.bat. A window opens; wait for "lobby ... ready". Leave it open.
       (Steam will show you as "playing Spacewar": that is Steam's free test app that carries
       the connection. Nothing to install or buy.)
    2. Start Hydroneer from Steam. Start a NEW game (new save slot).
    3. In the world, press F7. The Host window then says "co-op running, waiting for your friend".
  FRIEND:
    1. When the host's window says the lobby is ready, double-click Join.bat. It finds your
       friend's lobby through your Steam friends list. Leave it open.
       (If it cannot find it: ask the host for the lobby number shown in their window and run
        Join.bat --lobby <number> from a command prompt in this folder.)
    2. Start Hydroneer, start a NEW game, and in the world press F7.
    3. Your character jumps to the host's world position; the host's character appears.
  BOTH: press F7 right after loading, before anyone digs or moves things.

  To stop: quit Hydroneer, then close the Host/Join window.

LINUX (Steam + Proton)
  Hydroneer has no Linux version; Steam runs the Windows game through Proton. The mod runs inside
  the game, the connection program runs as a normal Linux program next to Steam.
  Setup, once:
    1. Play Hydroneer once through Steam on this PC (so Proton has set it up), then close it.
    2. Open a terminal in this folder and run:   bash install.sh
       It finds Hydroneer in your Steam libraries, backs up your saves from Proton's folder,
       and adds dwmapi.dll and a "ue4ss" folder to the game folder.
    3. In Steam: Library > right-click Hydroneer > Properties > General > Launch Options, paste:
           WINEDLLOVERRIDES="dwmapi=n,b" %command%
       (Without it, Proton ignores the mod.)
  Each time: run   bash host.sh   (host) or   bash join.sh   (friend) in a terminal instead of the
  .bat files, and leave the terminal open. Everything else is the same as above.
  Uninstall: bash uninstall.sh, then delete that Launch Options line.
  Played on Linux with Steam's regular package. Steam installed as a Flatpak or Snap is untested
  and may not let the connection program reach Steam.

UPDATING FROM AN OLDER VERSION
  Close the game, Uninstall (from the old or the new folder, both work), then Install from the
  new folder. Both players need the same version.

TROUBLESHOOTING
  - Send these when something goes wrong: run\coopnet-game.log and the "logs" folder (both in
    this folder), plus Hydroneer\Mining\Binaries\Win64\ue4ss\UE4SS.log.
  - "No friend is hosting": the host must run Host.bat first, and you must be Steam friends.
  - Game crashes at start after installing: run Uninstall.bat; your game version may differ.

UNINSTALL
  Double-click Uninstall.bat. It removes exactly the files Install.bat added. Your save backups
  stay in the "backups" folder.

INCLUDED THIRD-PARTY SOFTWARE (licenses in "licenses")
  - UE4SS (RE-UE4SS) v3.0.1-1181-g83330635, MIT license
  - Steamworks.NET Standalone 2025.164.1 (steam_api64.dll, libsteam_api.so), MIT license;
    Steamworks is Valve's
  - Python 3.12.10 (Python Software Foundation License)
