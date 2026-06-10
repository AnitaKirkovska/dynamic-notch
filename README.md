# 🖥️✨ Dynamic Notch

Put your Vellum assistant inside your MacBook's notch.

![Dynamic Notch listening](assets/preview.jpg)

The notch becomes your assistant: click it to open a chat drawer, hold **Ctrl+Option** anywhere to talk to it, press **ESC** to interrupt it mid-sentence. When your assistant picks up real work, a floating bulb pins to the top-right corner of your screen with a running spinner, then flips to a checkmark when the task is done.

Built by [Anita Kirkovska](https://github.com/AnitaKirkovska) and her assistant Ava, June 2026.

## What you get

- **Notch chat** — click the notch, a drawer slides out, replies stream in live as they generate
- **Hold-to-talk voice** — hold Ctrl+Option, speak, release. Your assistant starts talking after its *first sentence* (sentence-by-sentence TTS streaming, ~1s to first audio after generation starts)
- **Barge-in** — start talking while it's speaking and it shuts up and listens. ESC kills speech and the in-flight reply anywhere
- **Task bulb** — a floating face in the top-right corner that appears only when your assistant is doing actual work (tool use, not just chatting). Spinner while running, checkmark when done, click it to open the conversation
- **Real brain** — this is not a wrapper around a chat API. It talks to YOUR assistant: your memory, your tools, your context, through the same platform API the official macOS client uses

## Architecture

```
┌─────────────┐   localhost    ┌──────────────┐   X-Session-Token    ┌──────────────────┐
│  notch app  │ ─────────────▶ │  local relay │ ───────────────────▶ │  Vellum platform │
│   (Swift)   │ ◀───NDJSON──── │  (Python)    │ ◀────SSE stream───── │   (your brain)   │
└─────────────┘                └──────────────┘                      └──────────────────┘
```

Two pieces, both in `source/`:

1. **`main.swift`** — the notch UI. A borderless window over the physical notch (chat drawer, voice mode, task bulb). Talks only to localhost.
2. **`relay.py`** — a tiny local server (127.0.0.1:8473, never exposed). Holds your credentials, talks to the Vellum platform proxy API, streams replies back as NDJSON frames (`delta` / `audio` / `working` / `done` / `error`), and does per-sentence TTS (ElevenLabs primary, OpenAI fallback, or silent if you configure neither).

## Install

```bash
git clone https://github.com/AnitaKirkovska/dynamic-notch.git
cd dynamic-notch
bash source/install.sh
```

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`). The installer compiles the app, installs the relay as a launch agent, and creates `~/.dynamic-notch/` for config. Grant microphone + speech recognition when prompted.

Then complete **Auth** below — the notch runs without it, but replies need the brain connection.

## Auth: connecting your assistant

This plugin authenticates exactly the way the official Vellum macOS client does — an **assistant session token**, sent as an `X-Session-Token` header, plus your **organization ID** as `Vellum-Organization-Id`. Both headers are required on every call; missing the org header gets you a 400, a stale token gets you 401/403.

You need three values:

| Value | Where it goes | What it is |
|---|---|---|
| `assistant_id` | `~/.dynamic-notch/config.json` | Your assistant's UUID on the platform |
| `org_id` | `~/.dynamic-notch/config.json` | Your Vellum organization UUID |
| session token | `~/.dynamic-notch/session_token.txt` | Minted by WorkOS login (Django allauth headless), the same token the desktop client holds |

The easiest way to get all three — if you run the official Vellum macOS client, it already holds everything. In Terminal:

```bash
defaults read com.vellum.vellum-assistant
```

Your session token, assistant ID, and org ID are all in there. Alternatively, ask your assistant: it can read its own session credentials (`assistant credentials reveal --service vellum --field assistant_session_token`) and knows its own assistant and org IDs. Paste the token into `session_token.txt` (the installer creates it with `600` perms) and fill in `config.json`:

```json
{
  "assistant_id": "your-assistant-uuid",
  "org_id": "your-org-uuid",
  "conversation_key": "notch"
}
```

`conversation_key` names the conversation thread the notch lives in — all notch messages land in one persistent thread your assistant remembers.

**Token rotation:** session tokens expire. When the relay sees a 401/403 it returns a clear error in the chat ("session token expired..."). Fix = paste a fresh token into `session_token.txt`. No restart needed.

The relay handles the rest of the contract for you: `POST /v1/assistants/{id}/messages/` to send (202 + conversationId), SSE on `/v1/assistants/{id}/events?conversationKey=...` for live deltas, and a polling fallback path with snapshot-based reply detection (replies can get re-keyed server-side when sent mid-agent-loop — the relay handles that too).

## Voice (optional but worth it)

For spoken replies, give the relay a TTS key (either or both):

- **ElevenLabs** (recommended, ~0.5s latency): key in `~/.dynamic-notch/elevenlabs_key.txt`. Needs the `text_to_speech` permission on the key. Default voice is Kristen (casual BFF energy) on `eleven_flash_v2_5`; override with `elevenlabs_voice_id` / `elevenlabs_model` in `config.json`.
- **OpenAI** (fallback, ~3-5s): key in `~/.dynamic-notch/openai_key.txt`. Uses `gpt-4o-mini-tts` with the shimmer voice.

No key = voice mode still transcribes and sends, replies just come back as text only.

## Customization

- **Avatar in the notch:** drop `avatar.png` into `source/` before installing (or into `DynamicNotch.app/Contents/Resources/` after)
- **Bulb face:** drop `face.png` the same way — the task bulb shows this face (your own face is the move)
- **Conversation thread:** change `conversation_key` in config to start fresh or run multiple notch threads
- **Snappier replies:** pin a fast inference profile to the notch conversation server-side (`PUT /v1/assistants/{id}/conversations/{conversationId}/inference-profile` with `{"profile": "your-fast-profile", "ttlSeconds": null}`). A profile with thinking disabled and low effort makes voice round trips noticeably faster.

## Controls

| Action | What happens |
|---|---|
| Click the notch | Chat drawer opens, replies stream in live |
| Hold Ctrl+Option | Listening (release to send) |
| Talk while it speaks | Barge-in: it stops and listens |
| ESC | Interrupt everything, anywhere |
| Click the task bulb | Opens the conversation |
| Click outside | Drawer collapses |

## Security notes

- The relay binds to 127.0.0.1 only and is never reachable from the network
- Your session token lives in a `600`-perm file in your home directory and never enters the app bundle
- The Swift app holds zero credentials — it only talks to the local relay

## Repo layout

```
dynamic-notch/
├── package.json          # plugin manifest
├── README.md             # you are here
├── source/
│   ├── main.swift        # the notch app (UI, voice, task bulb)
│   ├── relay.py          # local relay (auth, streaming, TTS)
│   ├── Info.plist        # app bundle plist (mic + speech permissions)
│   └── install.sh        # one-command build + install
└── assets/               # built DMG will land here (not bundled yet)
```
