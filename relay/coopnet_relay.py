"""CoopNet relay: moves CoopNet's lines between the game and the other player's relay.

The game (UE4SS Lua, no sockets) appends one line per message to RUN/to_net.txt; the relay
sends each line to the peer as "<send_ns>|<line>" and appends what it receives to
RUN/from_net.txt as "<recv_ns>|<send_ns>|<line>". It also writes RUN/role.txt (host|client)
for the mod and prints a status line.

Late join: the host's mod puts its save in RUN/save_out/ and lists it in RUN/save_out.ready
(slot name, then one file name per line). The relay sends those files to the client's relay in
48 KB chunks with acks and resends (the save is ~21 MB and does not compress: EasyMultiSave
already compresses it), checks each file's SHA-256, and writes them to RUN/save_in/ plus
RUN/save_in.ready for the client's mod.

Transports:
  udp        direct UDP (host listens on --port; client sends to --host-addr:--port)
  steam      Steam lobbies + ISteamNetworkingMessages as AppID 480 (Spacewar), through
             Valve's relays: no IPs, no port forwarding. Needs the Steam API library from
             Steamworks.NET Standalone 2025.164.1 next to this file: steam_api64.dll on
             Windows, libsteam_api.so on Linux (64-bit only).
  mocksteam  test stand-in for steam on one PC: same lobby / session-accept / keep-alive
             rules, over localhost UDP, ids from --mock-id, lobby registry in --mock-dir.

Usage: python coopnet_relay.py --role host|client --transport steam|udp|mocksteam --run-dir DIR
"""
import argparse
import ctypes
import hashlib
import json
import os
import random
import socket
import sys
import time

KEEPALIVE_S = 1.0
PEER_TIMEOUT_S = 20.0
LOBBY_KEY = b"hydroneer_coopnet"
PROTO = b"1"


def now_ns():
    return time.time_ns()


class Log:
    def __init__(self, path):
        self.f = open(path, "a", encoding="utf-8") if path else None
        self.last_status = None

    def __call__(self, msg):
        line = f"{time.strftime('%H:%M:%S')} {msg}"
        print(line, flush=True)
        if self.f:
            self.f.write(line + "\n")
            self.f.flush()

    def status(self, msg):
        if msg != self.last_status:
            self.last_status = msg
            self(f"STATUS: {msg}")


# ---------------------------------------------------------------- transports
# Each transport: start(), pump() -> list[bytes] (game data received), send(bytes),
# connected() -> bool, describe() -> str, close(); and for the save transfer
# send_bulk(bytes) -> bool (False: try again later) and bulk_in (list of received bulk messages).

class UdpTransport:
    def __init__(self, args, log):
        self.log, self.role = log, args.role
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setblocking(False)
        if self.role == "host":
            self.sock.bind((args.bind, args.port))
            self.peer = None
        else:
            self.sock.bind(("0.0.0.0", 0))
            self.peer = (args.host_addr, args.port)
        self.last_rx = 0.0
        self.last_ka = 0.0
        self.bulk_in = []

    def start(self):
        self.log(f"udp transport, role {self.role}, " +
                 (f"listening on port {self.sock.getsockname()[1]}" if self.role == "host" else f"host {self.peer}"))

    def pump(self):
        out = []
        while True:
            try:
                data, addr = self.sock.recvfrom(65536)
            except (BlockingIOError, ConnectionResetError, OSError):
                break
            if self.role == "host" and self.peer != addr:
                self.peer = addr
                self.log(f"client address {addr}")
            self.last_rx = time.monotonic()
            if data[:1] == b"\x00":
                self.bulk_in.append(data[1:])
            elif data != b"K":
                out.append(data)
        if self.peer and time.monotonic() - self.last_ka > KEEPALIVE_S:
            self.last_ka = time.monotonic()
            self._raw(b"K")
        return out

    def send_bulk(self, data):
        if not self.peer:
            return False
        self._raw(b"\x00" + data)
        return True

    def _raw(self, data):
        try:
            self.sock.sendto(data, self.peer)
        except OSError:
            pass

    def send(self, data):
        if self.peer:
            self._raw(data)

    def connected(self):
        return self.peer is not None and time.monotonic() - self.last_rx < PEER_TIMEOUT_S

    def describe(self):
        return f"udp peer {self.peer}"

    def close(self):
        self.sock.close()


class SteamApi:
    """Flat Steamworks C API through ctypes (64-bit steam_api64.dll from Steamworks.NET)."""

    def __init__(self, dll_path, log):
        self.log = log
        self.d = ctypes.CDLL(dll_path)
        d = self.d
        u64, i32, b, vp, cp = ctypes.c_uint64, ctypes.c_int32, ctypes.c_bool, ctypes.c_void_p, ctypes.c_char_p

        def f(name, res, *argtypes):
            fn = getattr(d, name)
            fn.restype, fn.argtypes = res, list(argtypes)
            return fn
        self.InitFlat = f("SteamAPI_InitFlat", i32, ctypes.c_char_p)
        self.Shutdown = f("SteamAPI_Shutdown", None)
        self.IsSteamRunning = f("SteamAPI_IsSteamRunning", b)
        self.GetHSteamPipe = f("SteamAPI_GetHSteamPipe", i32)
        self.MD_Init = f("SteamAPI_ManualDispatch_Init", None)
        self.MD_RunFrame = f("SteamAPI_ManualDispatch_RunFrame", None, i32)
        self.MD_GetNext = f("SteamAPI_ManualDispatch_GetNextCallback", b, i32, vp)
        self.MD_Free = f("SteamAPI_ManualDispatch_FreeLastCallback", None, i32)
        self.MD_GetResult = f("SteamAPI_ManualDispatch_GetAPICallResult", b, i32, u64, vp, i32, i32, ctypes.POINTER(b))
        self.SteamUser = f("SteamAPI_SteamUser_v023", vp)
        self.GetSteamID = f("SteamAPI_ISteamUser_GetSteamID", u64, vp)
        self.SteamMM = f("SteamAPI_SteamMatchmaking_v009", vp)
        self.CreateLobby = f("SteamAPI_ISteamMatchmaking_CreateLobby", u64, vp, i32, i32)
        self.JoinLobby = f("SteamAPI_ISteamMatchmaking_JoinLobby", u64, vp, u64)
        self.LeaveLobby = f("SteamAPI_ISteamMatchmaking_LeaveLobby", None, vp, u64)
        self.SetLobbyData = f("SteamAPI_ISteamMatchmaking_SetLobbyData", b, vp, u64, cp, cp)
        self.GetLobbyData = f("SteamAPI_ISteamMatchmaking_GetLobbyData", cp, vp, u64, cp)
        self.GetLobbyOwner = f("SteamAPI_ISteamMatchmaking_GetLobbyOwner", u64, vp, u64)
        self.GetNumMembers = f("SteamAPI_ISteamMatchmaking_GetNumLobbyMembers", i32, vp, u64)
        self.GetMember = f("SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex", u64, vp, u64, i32)
        self.SteamFriends = f("SteamAPI_SteamFriends_v018", vp)
        self.SetRichPresence = f("SteamAPI_ISteamFriends_SetRichPresence", b, vp, cp, cp)
        self.ClearRichPresence = f("SteamAPI_ISteamFriends_ClearRichPresence", None, vp)
        self.GetFriendCount = f("SteamAPI_ISteamFriends_GetFriendCount", i32, vp, i32)
        self.GetFriendByIndex = f("SteamAPI_ISteamFriends_GetFriendByIndex", u64, vp, i32, i32)
        self.GetFriendGamePlayed = f("SteamAPI_ISteamFriends_GetFriendGamePlayed", b, vp, u64, vp)
        self.GetFriendName = f("SteamAPI_ISteamFriends_GetFriendPersonaName", cp, vp, u64)
        self.GetPersonaName = f("SteamAPI_ISteamFriends_GetPersonaName", cp, vp)
        self.SteamNM = f("SteamAPI_SteamNetworkingMessages_SteamAPI_v002", vp)
        self.SendToUser = f("SteamAPI_ISteamNetworkingMessages_SendMessageToUser", i32, vp, vp, vp, ctypes.c_uint32, i32, i32)
        self.ReceiveOnChannel = f("SteamAPI_ISteamNetworkingMessages_ReceiveMessagesOnChannel", i32, vp, i32, vp, i32)
        self.AcceptSession = f("SteamAPI_ISteamNetworkingMessages_AcceptSessionWithUser", b, vp, vp)
        self.CloseSession = f("SteamAPI_ISteamNetworkingMessages_CloseSessionWithUser", b, vp, vp)
        self.IdSet64 = f("SteamAPI_SteamNetworkingIdentity_SetSteamID64", None, vp, u64)
        self.IdGet64 = f("SteamAPI_SteamNetworkingIdentity_GetSteamID64", u64, vp)
        self.MsgRelease = f("SteamAPI_SteamNetworkingMessage_t_Release", None, vp)
        self.SteamNU = f("SteamAPI_SteamNetworkingUtils_SteamAPI_v004", vp)
        self.InitRelay = f("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", None, vp)
        try:   # ESteamNetworkingConfigValue values checked in Steamworks.NET 2025.164.1's metadata
            self.SetConfigInt = f("SteamAPI_ISteamNetworkingUtils_SetGlobalConfigValueInt32", b, vp, i32, i32)
        except AttributeError:
            self.SetConfigInt = None

    def identity(self, steamid):
        buf = ctypes.create_string_buffer(160)   # SteamNetworkingIdentity is 136 bytes; opaque
        self.IdSet64(buf, steamid)
        return buf


def is_lobby_id(v):
    # a lobby is a chat-type SteamID: universe 1 (public), account type 8 (chat) in the top byte
    return (v >> 56) == 0x01 and ((v >> 52) & 0xF) == 8


def lobby_created_id(data):
    """LobbyCreated_t {int32 result; uint64 lobby}. Steam packs callback structs with 8 on Windows
    (lobby at 8) and 4 on Linux/macOS (lobby at 4). Take the platform's offset, check that it reads
    a lobby id, else try the other one."""
    first, second = (8, 4) if sys.platform == "win32" else (4, 8)
    for off in (first, second):
        if len(data) >= off + 8:
            v = int.from_bytes(data[off:off + 8], "little")
            if is_lobby_id(v):
                return v
    return int.from_bytes(data[first:first + 8], "little") if len(data) >= first + 8 else 0


class CallbackMsg(ctypes.Structure):          # same layout on Windows and Linux x64 (pointer at 8)
    _fields_ = [("user", ctypes.c_int32), ("callback", ctypes.c_int32),
                ("param", ctypes.c_void_p), ("param_size", ctypes.c_int32)]


class SteamTransport:
    """Real Steam (AppID 480). Host: friends-only lobby tagged hydroneer_coopnet=1. Client: join
    --lobby, or find a friend hosting one. Data: channel 0 unreliable+NoNagle; control
    (keep-alive, hello, bye): channel 1 reliable."""

    CB_LOBBY_ENTER, CB_LOBBY_CHAT, CB_LOBBY_CREATED, CB_CALL_DONE = 504, 506, 513, 703
    CB_SESSION_REQUEST, CB_SESSION_FAILED = 1251, 1252
    SEND_UNRELIABLE_NONAGLE, SEND_RELIABLE = 1, 8

    def __init__(self, args, log):
        self.args, self.log, self.role = args, log, args.role
        here = os.path.dirname(os.path.abspath(__file__))
        lib = "steam_api64.dll" if sys.platform == "win32" else "libsteam_api.so"
        dll = args.dll or os.path.join(here, lib)
        appid = os.path.join(os.getcwd(), "steam_appid.txt")
        with open(appid, "w") as f:   # Steam reads it from the working directory
            f.write("480")
        self.api = SteamApi(dll, log)
        self.lobby = 0
        self.peer = 0
        self.me = 0
        self.last_rx = 0.0
        self.last_ka = 0.0
        self.pending_calls = {}
        self.sender_offset = None
        self.bulk_in = []

    # -- setup
    def start(self):
        a = self.api
        if not a.IsSteamRunning():
            raise SystemExit("Steam is not running. Start Steam, log in, and try again.")
        err = ctypes.create_string_buffer(1024)
        r = a.InitFlat(err)
        if r != 0:
            raise SystemExit(f"SteamAPI_InitFlat failed ({r}): {err.value.decode(errors='replace')}")
        a.MD_Init()
        self.pipe = a.GetHSteamPipe()
        self.user, self.mm, self.fr = a.SteamUser(), a.SteamMM(), a.SteamFriends()
        self.nm, self.nu = a.SteamNM(), a.SteamNU()
        self.me = a.GetSteamID(self.user)
        a.InitRelay(self.nu)
        # room and rate for the save transfer (defaults are a few hundred KB): send buffer 4 MB,
        # rate 512 KB/s to 8 MB/s. ESteamNetworkingConfigValue: SendBufferSize 9, SendRateMin 10, SendRateMax 11
        if a.SetConfigInt:
            for key, val in ((9, 4 * 1024 * 1024), (10, 512 * 1024), (11, 8 * 1024 * 1024)):
                ok = a.SetConfigInt(self.nu, key, val)
                if not ok:
                    self.log(f"could not set Steam networking config {key} (save transfer may be slower)")
        name = (a.GetPersonaName(self.fr) or b"?").decode(errors="replace")
        self.log(f"steam transport as AppID 480 (Spacewar), signed in as {name} ({self.me})")
        if self.role == "host":
            call = a.CreateLobby(self.mm, 1, 2)            # 1 = friends-only, 2 members
            self.pending_calls[call] = "create"
            self.log("creating a friends-only lobby ...")
        else:
            lobby = self.args.lobby or self.find_friend_lobby()
            if not lobby:
                raise SystemExit("No friend is hosting Hydroneer co-op right now. Ask your friend to start hosting (Host.bat or host.sh) "
                                 "first (and to be on your Steam friends list), or pass --lobby <id>.")
            self.join(lobby)

    def find_friend_lobby(self):
        a = self.api
        info = ctypes.create_string_buffer(24)              # FriendGameInfo_t
        found = []
        for i in range(a.GetFriendCount(self.fr, 4)):        # 4 = immediate friends
            fid = a.GetFriendByIndex(self.fr, i, 4)
            ctypes.memset(info, 0, 24)
            if a.GetFriendGamePlayed(self.fr, fid, info):
                game = int.from_bytes(info.raw[0:8], "little") & 0xFFFFFF
                lobby = int.from_bytes(info.raw[16:24], "little")
                if game == 480 and lobby:
                    nm = (a.GetFriendName(self.fr, fid) or b"?").decode(errors="replace")
                    found.append((nm, fid, lobby))
        if not found:
            return 0
        for n, (nm, fid, lobby) in enumerate(found, 1):
            self.log(f"  {n}. {nm} is hosting a Spacewar lobby {lobby}")
        if len(found) == 1:
            return found[0][2]
        if not sys.stdin or not sys.stdin.isatty():
            # started from the launcher window: no keyboard here, ask for the lobby number instead
            raise SystemExit("Several friends are hosting. Put the lobby number of the one you want "
                             "(shown in their window, and listed above) in the Lobby box and press Join again.")
        try:
            pick = int(input("Which friend? number: "))
            return found[pick - 1][2]
        except (ValueError, IndexError, EOFError):
            return 0

    def join(self, lobby):
        call = self.api.JoinLobby(self.mm, lobby)
        self.pending_calls[call] = "join"
        self.log(f"joining lobby {lobby} ...")

    # -- callbacks
    def _param(self, ptr, size):
        return ctypes.string_at(ptr, size) if ptr and size > 0 else b""

    def _handle(self, cb, data):
        a = self.api
        if cb == self.CB_LOBBY_CREATED:
            result, lobby = int.from_bytes(data[0:4], "little"), lobby_created_id(data)
            if result != 1:
                self.log(f"lobby creation failed (EResult {result})")
                return
            if self.lobby == lobby:
                return                       # arrives twice on real Steam (call result + broadcast)
            self.lobby = lobby
            a.SetLobbyData(self.mm, lobby, LOBBY_KEY, PROTO)
            a.SetRichPresence(self.fr, b"connect", f"+connect_lobby {lobby}".encode())
            a.SetRichPresence(self.fr, b"status", b"Hosting Hydroneer co-op")
            self.log(f"lobby {lobby} ready. Your friend runs Join.bat or join.sh (they find you in their Steam friends).")
        elif cb == self.CB_LOBBY_ENTER:
            lobby, response = int.from_bytes(data[0:8], "little"), int.from_bytes(data[16:20], "little")
            if self.role != "client":
                return
            if response != 1:
                raise SystemExit(f"could not enter lobby {lobby} (response {response})")
            tag = a.GetLobbyData(self.mm, lobby, LOBBY_KEY) or b""
            if tag != PROTO:
                a.LeaveLobby(self.mm, lobby)
                raise SystemExit("That lobby is not a Hydroneer co-op game (or a different version).")
            self.lobby = lobby
            self.peer = a.GetLobbyOwner(self.mm, lobby)
            self.log(f"in lobby {lobby}, host is {self.peer}")
            self._control(b"HELLO")
        elif cb == self.CB_LOBBY_CHAT:
            changed, state = int.from_bytes(data[8:16], "little"), int.from_bytes(data[24:28], "little")
            if changed == self.peer and state & (0x2 | 0x4 | 0x8 | 0x10):
                self.log("the other player left the lobby")
                self.peer = 0 if self.role == "host" else self.peer
        elif cb == self.CB_SESSION_REQUEST:
            ident = ctypes.create_string_buffer(data[:136], 160)
            sid = a.IdGet64(ident)
            ok = self._allowed(sid)
            if ok:
                a.AcceptSession(self.nm, ident)
                if self.role == "host" and not self.peer:
                    self.peer = sid
                self.log(f"accepted session from {sid}")
            else:
                self.log(f"refused session from {sid} (not in our lobby)")
        elif cb == self.CB_SESSION_FAILED:
            self.log("a Steam networking session failed (peer unreachable or left)")

    def _allowed(self, sid):
        a = self.api
        if self.role == "client":
            return sid == self.peer
        if not self.lobby:
            return False
        return any(a.GetMember(self.mm, self.lobby, i) == sid for i in range(a.GetNumMembers(self.mm, self.lobby)))

    def _dispatch(self):
        a = self.api
        a.MD_RunFrame(self.pipe)
        msg = CallbackMsg()
        while a.MD_GetNext(self.pipe, ctypes.byref(msg)):
            try:
                if msg.callback == self.CB_CALL_DONE:
                    raw = self._param(msg.param, msg.param_size)
                    call = int.from_bytes(raw[0:8], "little")
                    cbid = int.from_bytes(raw[8:12], "little", signed=True)
                    size = int.from_bytes(raw[12:16], "little")
                    buf = ctypes.create_string_buffer(max(size, 1))
                    failed = ctypes.c_bool(False)
                    if a.MD_GetResult(self.pipe, call, buf, size, cbid, ctypes.byref(failed)) and not failed.value:
                        self._handle(cbid, buf.raw[:size])
                    self.pending_calls.pop(call, None)
                else:
                    self._handle(msg.callback, self._param(msg.param, msg.param_size))
            finally:
                a.MD_Free(self.pipe)

    # -- messages
    def _send(self, data, channel, flags):
        if not self.peer:
            return 0
        a = self.api
        ident = a.identity(self.peer)
        buf = ctypes.create_string_buffer(data, len(data))
        return a.SendToUser(self.nm, ident, buf, len(data), flags, channel)

    def send_bulk(self, data):
        return self._send(data, 2, self.SEND_RELIABLE) == 1      # 1 = k_EResultOK

    def _control(self, data):
        self._send(data, 1, self.SEND_RELIABLE)

    def _receive(self, channel):
        a = self.api
        ptrs = (ctypes.c_void_p * 64)()
        n = a.ReceiveOnChannel(self.nm, channel, ptrs, 64)
        out = []
        for i in range(n):
            p = ptrs[i]
            data_ptr = ctypes.c_void_p.from_address(p).value
            size = ctypes.c_int32.from_address(p + 8).value      # x64: size at 8
            # sender identity: 16 on x64 per the playbook; try 16 then 12 and keep the one that works
            sender = 0
            for off in ((self.sender_offset,) if self.sender_offset else (16, 12)):
                sender = a.IdGet64(ctypes.c_void_p(p + off))
                if sender:
                    if self.sender_offset != off:
                        self.sender_offset = off
                        self.log(f"message sender identity at offset {off}")
                    break
            data = ctypes.string_at(data_ptr, size) if data_ptr and size > 0 else b""
            a.MsgRelease(ctypes.c_void_p(p))
            if self.role == "host" and sender and not self.peer and self._allowed(sender):
                self.peer = sender
            if sender and sender == self.peer:
                out.append(data)
        return out

    def pump(self):
        self._dispatch()
        for c in self._receive(1):
            self.last_rx = time.monotonic()
            if c == b"BYE":
                self.log("the other player closed their relay")
        bulk = self._receive(2)
        if bulk:
            self.last_rx = time.monotonic()
            self.bulk_in.extend(bulk)
        data = self._receive(0)
        if data:
            self.last_rx = time.monotonic()
        if self.peer and time.monotonic() - self.last_ka > KEEPALIVE_S:
            self.last_ka = time.monotonic()
            self._control(b"K")
        return data

    def send(self, data):
        self._send(data, 0, self.SEND_UNRELIABLE_NONAGLE)

    def connected(self):
        return bool(self.peer) and time.monotonic() - self.last_rx < PEER_TIMEOUT_S

    def describe(self):
        return f"steam lobby {self.lobby} peer {self.peer}"

    def close(self):
        a = self.api
        try:
            if self.peer:
                self._control(b"BYE")
            if self.lobby:
                a.LeaveLobby(self.mm, self.lobby)
            a.ClearRichPresence(self.fr)
            time.sleep(0.2)
            a.Shutdown()
        except Exception:
            pass


class MockSteamTransport:
    """One-PC stand-in for SteamTransport: lobby registry file, ids from --mock-id, messages over
    localhost UDP, first message from a stranger held until accepted (like real Steam)."""

    def __init__(self, args, log):
        self.args, self.log, self.role = args, log, args.role
        self.me = 900000000 + args.mock_id
        self.reg = os.path.join(args.mock_dir, "lobby.json")
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.bind(("127.0.0.1", 0))
        self.sock.setblocking(False)
        self.lobby, self.peer, self.peer_port = 0, 0, None
        self.accepted, self.held = set(), {}
        self.last_rx = self.last_ka = 0.0
        self.bulk_in = []

    def start(self):
        self.log(f"mocksteam transport, id {self.me}, port {self.sock.getsockname()[1]}")
        if self.role == "host":
            self.lobby = 109775240000000000 + self.me
            os.makedirs(self.args.mock_dir, exist_ok=True)
            with open(self.reg, "w") as f:
                json.dump({"lobby": self.lobby, "owner": self.me, "port": self.sock.getsockname()[1],
                           "tag": PROTO.decode()}, f)
            self.log(f"lobby {self.lobby} ready")
        else:
            deadline = time.monotonic() + 600
            while not os.path.exists(self.reg):
                if time.monotonic() > deadline:
                    raise SystemExit("mock: no lobby")
                if self.args.stop_file and os.path.exists(self.args.stop_file):
                    raise SystemExit("stop requested while waiting for a lobby")
                time.sleep(0.2)
            with open(self.reg) as f:
                lob = json.load(f)
            if lob.get("tag") != PROTO.decode():
                raise SystemExit("mock: that lobby is not a Hydroneer co-op game")
            self.lobby, self.peer, self.peer_port = lob["lobby"], lob["owner"], lob["port"]
            self.accepted.add(self.peer)       # clients accept only the host
            self.log(f"in lobby {self.lobby}, host is {self.peer}")
            self._raw(1, b"HELLO")

    def _raw(self, channel, data):
        # test only: lose a share of the save-transfer messages (--mock-drop), to exercise resends
        if channel == 2 and self.args.mock_drop and random.random() < self.args.mock_drop:
            return
        if self.peer_port:
            hdr = self.me.to_bytes(8, "little") + bytes([channel]) + self.sock.getsockname()[1].to_bytes(2, "little")
            try:
                self.sock.sendto(hdr + data, ("127.0.0.1", self.peer_port))
            except OSError:
                pass

    def pump(self):
        out = []
        while True:
            try:
                pkt, _ = self.sock.recvfrom(65536)
            except (BlockingIOError, ConnectionResetError, OSError):
                break
            sender, channel = int.from_bytes(pkt[0:8], "little"), pkt[8]
            port, data = int.from_bytes(pkt[9:11], "little"), pkt[11:]
            if sender not in self.accepted:
                # session request: host accepts lobby members (the mock lobby has the client once it says HELLO)
                if self.role == "host" and not self.peer:
                    self.accepted.add(sender)
                    self.peer, self.peer_port = sender, port
                    self.log(f"accepted session from {sender}")
                else:
                    self.held.setdefault(sender, 0)
                    self.held[sender] += 1
                    continue
            if sender != self.peer:
                continue
            self.last_rx = time.monotonic()
            if channel == 0:
                out.append(data)
            elif channel == 2:
                self.bulk_in.append(data)
        if self.peer and time.monotonic() - self.last_ka > KEEPALIVE_S:
            self.last_ka = time.monotonic()
            self._raw(1, b"K")
        return out

    def send(self, data):
        self._raw(0, data)

    def send_bulk(self, data):
        if not self.peer_port:
            return False
        self._raw(2, data)
        return True

    def connected(self):
        return bool(self.peer) and time.monotonic() - self.last_rx < PEER_TIMEOUT_S

    def describe(self):
        return f"mocksteam lobby {self.lobby} peer {self.peer}"

    def close(self):
        self._raw(1, b"BYE")
        if self.role == "host" and os.path.exists(self.reg):
            os.remove(self.reg)
        self.sock.close()


# ---------------------------------------------------------------- save transfer (late join)
# Messages on the bulk channel:
#   H + json {"tid", "slot", "files": [[name, size, sha256], ...], "chunks"}   header
#   C + tid(4) + index(4) + payload                                         chunk (48 KB)
#   A + tid(4) + index(4, 0xFFFFFFFF = header)                              ack
#   D + tid(4)                                                              all files written
# Unacked messages are sent again after 1 s, so it works over lossy test transports too.
CHUNK = 48 * 1024
WINDOW = 8
RESEND_S = 1.0


class SaveSender:
    def __init__(self, t, log, tid, slot, files):
        self.t, self.log, self.tid = t, log, tid
        self.blob = b"".join(d for _, d in files)
        self.n = (len(self.blob) + CHUNK - 1) // CHUNK
        meta = [[name, len(d), hashlib.sha256(d).hexdigest()] for name, d in files]
        self.header = b"H" + json.dumps({"tid": tid, "slot": slot, "files": meta, "chunks": self.n}).encode()
        self.header_acked = False
        self.sent_at = {}            # chunk index -> time sent (unacked)
        self.acked = set()
        self.next = 0
        self.last_header = 0.0
        self.done = False
        self.t0 = time.monotonic()
        self.last_report = 0.0
        log(f"save transfer {tid}: slot {slot}, {len(files)} files, {len(self.blob) / 1e6:.1f} MB in {self.n} chunks")

    def _chunk(self, i):
        return b"C" + self.tid.to_bytes(4, "little") + i.to_bytes(4, "little") + self.blob[i * CHUNK:(i + 1) * CHUNK]

    def on_msg(self, m):
        if m[:1] == b"A" and int.from_bytes(m[1:5], "little") == self.tid:
            i = int.from_bytes(m[5:9], "little")
            if i == 0xFFFFFFFF:
                self.header_acked = True
            else:
                self.acked.add(i)
                self.sent_at.pop(i, None)
        elif m[:1] == b"D" and int.from_bytes(m[1:5], "little") == self.tid:
            self.done = True
            self.log(f"save transfer {self.tid}: the friend has the save ({time.monotonic() - self.t0:.0f} s)")

    def tick(self):
        now = time.monotonic()
        if not self.header_acked:
            if now - self.last_header > RESEND_S:
                self.last_header = now
                self.t.send_bulk(self.header)
            return
        # resend what was not acked in time, then fill the window with new chunks
        for i, ts in list(self.sent_at.items()):
            if now - ts > RESEND_S:
                if self.t.send_bulk(self._chunk(i)):
                    self.sent_at[i] = now
        while len(self.sent_at) < WINDOW and self.next < self.n:
            if not self.t.send_bulk(self._chunk(self.next)):
                break                                    # Steam's buffer is full: next tick
            self.sent_at[self.next] = now
            self.next += 1
        if now - self.last_report > 3:
            self.last_report = now
            self.log(f"sending save: {100 * len(self.acked) // max(1, self.n)}% "
                     f"({len(self.acked) * CHUNK / 1e6:.1f} of {len(self.blob) / 1e6:.1f} MB)")


class SaveReceiver:
    def __init__(self, t, log, run_dir):
        self.t, self.log, self.run_dir = t, log, run_dir
        self.cur = None              # tid, meta, buffer, have
        self.finished = set()
        self.last_report = 0.0

    def _ack(self, tid, i):
        self.t.send_bulk(b"A" + tid.to_bytes(4, "little") + i.to_bytes(4, "little"))

    def on_msg(self, m):
        kind = m[:1]
        if kind == b"H":
            meta = json.loads(m[1:].decode())
            tid = meta["tid"]
            self._ack(tid, 0xFFFFFFFF)
            if tid in self.finished:
                self.t.send_bulk(b"D" + tid.to_bytes(4, "little"))
                return
            if not self.cur or self.cur["tid"] != tid:
                total = sum(f[1] for f in meta["files"])
                self.cur = {"tid": tid, "meta": meta, "buf": bytearray(total), "have": set(), "t0": time.monotonic()}
                self.log(f"receiving the host's save (slot {meta['slot']}, {total / 1e6:.1f} MB)")
        elif kind == b"C" and self.cur:
            tid, i = int.from_bytes(m[1:5], "little"), int.from_bytes(m[5:9], "little")
            if tid != self.cur["tid"]:
                return
            self._ack(tid, i)
            if i not in self.cur["have"]:
                payload = m[9:]
                self.cur["buf"][i * CHUNK:i * CHUNK + len(payload)] = payload
                self.cur["have"].add(i)
            now = time.monotonic()
            n = self.cur["meta"]["chunks"]
            if now - self.last_report > 3:
                self.last_report = now
                self.log(f"receiving save: {100 * len(self.cur['have']) // max(1, n)}%")
            if len(self.cur["have"]) == n:
                self._finish()

    def _finish(self):
        c = self.cur
        meta, buf = c["meta"], bytes(c["buf"])
        out = os.path.join(self.run_dir, "save_in")
        os.makedirs(out, exist_ok=True)
        pos, names = 0, []
        for name, size, sha in meta["files"]:
            data = buf[pos:pos + size]
            pos += size
            if hashlib.sha256(data).hexdigest() != sha or os.path.basename(name) != name:
                self.log(f"save transfer: {name} arrived damaged; asking again")
                self.cur = None
                return
            with open(os.path.join(out, name + ".part"), "wb") as f:
                f.write(data)
            os.replace(os.path.join(out, name + ".part"), os.path.join(out, name))
            names.append(name)
        ready = os.path.join(self.run_dir, "save_in.ready")
        with open(ready + ".part", "w", encoding="utf-8", newline="\n") as f:
            f.write(meta["slot"] + "\n" + "\n".join(names) + "\n")
        os.replace(ready + ".part", ready)
        self.finished.add(c["tid"])
        self.t.send_bulk(b"D" + c["tid"].to_bytes(4, "little"))
        self.log(f"got the host's save: {len(names)} files, all SHA-256 checked "
                 f"({time.monotonic() - c['t0']:.0f} s); the game loads it now")
        self.cur = None


# ---------------------------------------------------------------- relay loop

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--role", choices=["host", "client"], required=True)
    p.add_argument("--transport", choices=["steam", "udp", "mocksteam"], default="steam")
    p.add_argument("--run-dir", required=True, help="folder shared with the game mod")
    p.add_argument("--log")
    p.add_argument("--port", type=int, default=47777)
    p.add_argument("--bind", default="0.0.0.0")
    p.add_argument("--host-addr", default="127.0.0.1")
    p.add_argument("--lobby", type=int, default=0)
    p.add_argument("--dll")
    p.add_argument("--mock-id", type=int, default=1)
    p.add_argument("--mock-dir", default=".")
    p.add_argument("--mock-drop", type=float, default=0.0, help="test only: share of save-transfer messages the mock transport loses")
    p.add_argument("--max-seconds", type=float, default=0, help="test: stop after this long")
    p.add_argument("--stop-file", help="stop cleanly (leave the lobby, sign off) when this file appears")
    args = p.parse_args()

    os.makedirs(args.run_dir, exist_ok=True)
    log = Log(args.log)
    to_net = os.path.join(args.run_dir, "to_net.txt")
    from_net = os.path.join(args.run_dir, "from_net.txt")
    game_status = os.path.join(args.run_dir, "status-game.txt")
    # fresh exchange files for this session (and no status left over from an earlier one);
    # then tell the mod our role
    for path in (to_net, from_net, game_status):
        open(path, "w").close()
    # no half-finished save transfer from an earlier session
    for name in ("save_out.ready", "save_out.sent", "save_in.ready"):
        try:
            os.remove(os.path.join(args.run_dir, name))
        except OSError:
            pass
    with open(os.path.join(args.run_dir, "role.txt"), "w") as f:
        f.write(args.role + "\n")

    # errors before the loop go into the log too: the launcher window shows the log, not a console
    try:
        t = {"udp": UdpTransport, "steam": SteamTransport, "mocksteam": MockSteamTransport}[args.transport](args, log)
        t.start()
    except SystemExit as e:
        log(f"STOPPED: {e}")
        raise
    except Exception as e:
        log(f"STOPPED: unexpected error: {e!r}")
        raise
    inbox = open(from_net, "a", encoding="utf-8", newline="\n")
    outbox = open(to_net, "r", encoding="utf-8", newline="\n")
    buf = ""
    sent = recv = 0
    lat = []
    t0 = last_report = last_stop_check = time.monotonic()
    if args.stop_file and os.path.exists(args.stop_file):
        os.remove(args.stop_file)          # a stop request left over from an earlier session
    last_game = ""
    sender, receiver, next_tid = None, SaveReceiver(t, log, args.run_dir), int(time.time()) & 0x7FFFFFFF
    save_out_ready = os.path.join(args.run_dir, "save_out.ready")
    last_save_check = 0.0
    log("relay running. Leave this window open while you play; close it to stop co-op.")
    try:
        while True:
            for data in t.pump():
                text = data.decode("utf-8", "replace")
                try:
                    lat.append((now_ns() - int(text.split("|", 1)[0])) / 1e6)
                except ValueError:
                    pass
                inbox.write(f"{now_ns()}|{text}\n")
                recv += 1
            inbox.flush()
            # save transfer
            for m in t.bulk_in:
                if args.role == "host" and sender:
                    sender.on_msg(m)
                elif args.role == "client":
                    receiver.on_msg(m)
            t.bulk_in.clear()
            if args.role == "host":
                if sender:
                    if sender.done:
                        sender = None
                        try:
                            os.replace(save_out_ready, save_out_ready[:-6] + ".sent")
                        except OSError:
                            pass
                    else:
                        sender.tick()
                elif time.monotonic() - last_save_check > 0.5 and t.connected():
                    last_save_check = time.monotonic()
                    if os.path.exists(save_out_ready):
                        try:
                            with open(save_out_ready, encoding="utf-8") as f:
                                lines = [x.strip() for x in f.read().splitlines() if x.strip()]
                            slot, names = lines[0], lines[1:]
                            files = []
                            for nm in names:
                                with open(os.path.join(args.run_dir, "save_out", nm), "rb") as f:
                                    files.append((nm, f.read()))
                            next_tid += 1
                            sender = SaveSender(t, log, next_tid, slot, files)
                        except (OSError, IndexError) as e:
                            log(f"save transfer: cannot read the save files yet ({e})")
            chunk = outbox.read()
            if chunk:
                buf += chunk
                while "\n" in buf:
                    line, buf = buf.split("\n", 1)
                    if line:
                        t.send(f"{now_ns()}|{line}".encode("utf-8"))
                        sent += 1
            now = time.monotonic()
            if now - last_report >= 5:
                last_report = now
                g = ""
                try:
                    with open(game_status, encoding="utf-8") as f:
                        g = f.read().strip()
                except OSError:
                    pass
                if g and g != last_game:
                    last_game = g
                    log(f"game: {g}")
                extra = ""
                if lat:
                    s = sorted(lat)
                    extra = f", one-way ms p50 {s[len(s)//2]:.1f} max {s[-1]:.1f} (meaningful on one PC only)"
                    lat = []
                peer = "connected" if t.connected() else "waiting for the other player"
                log.status(f"{peer}; {t.describe()}")
                log(f"sent {sent} received {recv}{extra}")
            if args.max_seconds and now - t0 > args.max_seconds:
                break
            if args.stop_file and now - last_stop_check > 0.3:
                last_stop_check = now
                if os.path.exists(args.stop_file):
                    log("stop requested")
                    break
            time.sleep(0.002)
    except (KeyboardInterrupt, BrokenPipeError):
        pass
    finally:
        t.close()
        log("relay stopped")


if __name__ == "__main__":
    main()
