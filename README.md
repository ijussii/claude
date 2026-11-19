# Anon — anonymous username-only messenger for iPhone

Text and voice-call people using nothing but a username. No email, no phone number, no password.

```
┌──────────┐   wss (JSON)    ┌──────────────┐   wss (JSON)    ┌──────────┐
│ iPhone A │ ──────────────▶ │ relay server │ ──────────────▶ │ iPhone B │
└────┬─────┘  ciphertext +   └──────────────┘  ciphertext +   └────┬─────┘
     │        call signaling                    call signaling      │
     └────────────── WebRTC audio, peer-to-peer (Wi-Fi) ────────────┘
```

| Piece | What it does |
|---|---|
| `server/` | Node 22 relay (`ws` + built-in SQLite). Registers usernames, queues messages for offline users until they ack, relays call signaling. Sees only ciphertext. |
| `ios/` | SwiftUI app (iOS 17+). Keychain identity, end-to-end encryption, chat UI, WebRTC voice calls. |

## How anonymity & security work

* **Account = username + random secret token.** Registering returns a 256-bit token; the server stores only its hash. The token and your private key live in the iOS Keychain. There is no recovery: lose the device data, lose the account.
* **End-to-end encrypted messages.** Each device makes an X25519 key pair at signup and uploads the public half. Messages are encrypted with ChaCha20-Poly1305 (key via ECDH + HKDF). The relay can't read them and deletes them once the recipient acks.
* **Safety number** (🔒 button in a chat) lets two people confirm out-of-band that the server didn't swap keys.
* **Calls are peer-to-peer** WebRTC audio (DTLS-SRTP encrypted). The server only relays offer/answer/ICE.
* The server necessarily sees IP addresses and who talks to whom (metadata). Put it behind a privacy-respecting host/proxy if that matters to you.

## Run it

### 1. Server
```sh
cd server
npm install
npm test          # 10 tests
npm start         # listens on :8080, DB in ./messenger.db (PORT / DB_PATH env vars)
```
For anything beyond local testing, put it behind TLS (Caddy/nginx/Fly/etc.) so the app can use `wss://`.

### 2. iPhone app (needs a Mac with Xcode 16+)
```sh
brew install xcodegen
cd ios
xcodegen generate         # creates AnonMessenger.xcodeproj (from project.yml)
open AnonMessenger.xcodeproj
```
1. In Xcode, set your Team under *Signing & Capabilities* and change the bundle id (`com.example.anon` in `project.yml`).
2. Run on your iPhone. On the first screen, enter your server address in **Server** — for testing on the same Wi-Fi use your Mac's LAN IP, e.g. `ws://192.168.1.20:8080`.
3. Install on a second device (or the simulator), create another username, and start chatting / calling.

Voice calls need a real device for meaningful testing (the simulator has no usable mic path for WebRTC).

## Current limitations / next steps

* **Foreground only.** There are no push notifications, so messages arrive and calls ring only while the app is open (queued messages are delivered when you return). Next step: APNs for message alerts and PushKit + CallKit for native incoming-call UI — this needs an Apple Developer account and a push-sending path on the server.
* **No TURN server.** Calls work when phones are on the same Wi-Fi or have friendly NATs (public STUN is used). For reliability across strict/cellular NATs, add a TURN server (e.g. coturn) to `Config.iceServers`.
* Single device per account (a second login signs out the first).
* No groups, media, read receipts, or message deletion yet. Local history is stored unencrypted-at-rest apart from iOS file protection.
* Usernames are first-come; there's basic per-IP signup throttling but no abuse/blocking tools.

## Status

The server is covered by automated tests (`server/test`). **The Swift code has not yet been compiled or run on a device** — it was written without Xcode available. `.github/workflows/ci.yml` builds it on a macOS runner; expect to fix a few compile errors on first build, and treat call audio as needing on-device verification.
