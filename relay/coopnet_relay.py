"""CoopNet relay: moves CoopNet's lines between the game and the other player's relay.

The game (UE4SS Lua, no sockets) appends one line per message to RUN/to_net.txt; the relay
sends each line to the peer as "<send_ns>|<line>" and appends what it receives to
RUN/from_net.txt as "<recv_ns>|<send_ns>|<line>". It also writes RUN/role.txt (host|client)
for the mod and prints a status line.

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
import json
import os
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
# connected() -> bool, describe() -> str, close().

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
            if data != b"K":
                out.append(data)
        if self.peer and time.monotonic() - self.last_ka > KEEPALIVE_S:
            self.last_ka = time.monotonic()
            self._raw(b"K")
        return out

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
            return
        a = self.api
        ident = a.identity(self.peer)
        buf = ctypes.create_string_buffer(data, len(data))
        a.SendToUser(self.nm, ident, buf, len(data), flags, channel)

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
        if self.peer and time.monotonic() - self.last_ka > KEEPALIVE_S:
            self.last_ka = time.monotonic()
            self._raw(1, b"K")
        return out

    def send(self, data):
        self._raw(0, data)

    def connected(self):
        return bool(self.peer) and time.monotonic() - self.last_rx < PEER_TIMEOUT_S

    def describe(self):
        return f"mocksteam lobby {self.lobby} peer {self.peer}"

    def close(self):
        self._raw(1, b"BYE")
        if self.role == "host" and os.path.exists(self.reg):
            os.remove(self.reg)
        self.sock.close()


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
