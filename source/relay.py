#!/usr/bin/env python3
"""Dynamic Notch local relay. The notch app POSTs here; the relay talks to YOUR
assistant's brain in the cloud via the Vellum platform desktop proxy API,
authenticated the same way the macOS desktop client is: an assistant session
token sent as X-Session-Token plus your Vellum-Organization-Id header.

Endpoints (all on 127.0.0.1, never exposed):
/chat        -> classic request/response
/chat-stream -> NDJSON stream: text deltas + per-sentence TTS audio
/tts             -> one-shot TTS (greeting line etc.)

Config lives in ~/.dynamic-notch/ (see README)."""
import base64, json, os, re, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8473
HERE = os.path.expanduser("~/.dynamic-notch")

# --- Your assistant: Vellum platform proxy API ------------------------------
# All identity comes from ~/.dynamic-notch/config.json:
#   { "assistant_id": "...", "org_id": "...", "conversation_key": "notch" }
def _load_config():
    try:
        with open(os.path.join(HERE, "config.json")) as f:
            return json.load(f)
    except Exception:
        raise RuntimeError("missing or invalid ~/.dynamic-notch/config.json (see README)")

_CFG = _load_config()
ASSISTANT_ID = _CFG["assistant_id"]
ORG_ID = _CFG["org_id"]
PLATFORM = _CFG.get("platform_base", "https://platform.vellum.ai") + "/v1/assistants/" + ASSISTANT_ID
CONV_KEY = _CFG.get("conversation_key", "notch")
POLL_INTERVAL = 0.8
POLL_TIMEOUT = 110
STREAM_TIMEOUT = 110

TTS_VOICE = "shimmer"
TTS_MODEL = "gpt-4o-mini-tts"

# ElevenLabs (primary TTS): Kristen, friendly casual BFF, flash model for speed
EL_VOICE_ID = _CFG.get("elevenlabs_voice_id", "Awx8TeMHHpDzbm42nIB6")  # default: Kristen (casual BFF)
EL_MODEL = _CFG.get("elevenlabs_model", "eleven_flash_v2_5")

_EMOJI_RE = re.compile(
    "[\U0001F000-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF\uFE0F\u200D]+"
)


def _read_secret(name):
    path = os.path.join(HERE, name)
    if os.path.exists(path):
        with open(path) as f:
            return f.read().strip()
    return None


def openai_key():
    return os.environ.get("OPENAI_API_KEY") or _read_secret("openai_key.txt")


def elevenlabs_key():
    return os.environ.get("ELEVENLABS_API_KEY") or _read_secret("elevenlabs_key.txt")


def session_token():
    return _read_secret("session_token.txt")


def strip_for_tts(text):
    return _EMOJI_RE.sub("", text).strip()


def tts_elevenlabs(text, pad=True):
    key = elevenlabs_key()
    if not key:
        return None
    spoken = strip_for_tts(text)
    if not spoken:
        return None
    if pad:
        spoken = '<break time="0.4s" /> ' + spoken
    req = urllib.request.Request(
        "https://api.elevenlabs.io/v1/text-to-speech/%s?output_format=mp3_44100_64" % EL_VOICE_ID,
        data=json.dumps({"text": spoken[:4000], "model_id": EL_MODEL}).encode(),
        headers={"xi-api-key": key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return base64.b64encode(r.read()).decode()


def tts_openai(text):
    key = openai_key()
    if not key:
        return None
    req = urllib.request.Request(
        "https://api.openai.com/v1/audio/speech",
        data=json.dumps({
            "model": TTS_MODEL, "voice": TTS_VOICE,
            "input": strip_for_tts(text)[:4000], "response_format": "mp3",
            "instructions": "Young woman's voice, bright and feminine. Speak at a quick, lively pace like a best friend mid-conversation. Warm, playful, never robotic, never deep or masculine.",
        }).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as r:
        return base64.b64encode(r.read()).decode()


def tts(text, pad=True):
    # ElevenLabs first (fast), OpenAI fallback
    try:
        audio = tts_elevenlabs(text, pad=pad)
        if audio:
            return audio
    except Exception:
        pass
    try:
        return tts_openai(text)
    except Exception:
        return None


def platform_call(path, payload=None):
    tok = session_token()
    if not tok:
        raise RuntimeError("no session token at ~/.dynamic-notch/session_token.txt (see README: Auth)")
    req = urllib.request.Request(
        PLATFORM + path,
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={
            "X-Session-Token": tok,
            "Vellum-Organization-Id": ORG_ID,
            "Content-Type": "application/json",
        },
        method="POST" if payload is not None else "GET",
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def open_event_stream():
    """Open the live SSE event stream for the notch conversation."""
    tok = session_token()
    if not tok:
        raise RuntimeError("no session token")
    req = urllib.request.Request(
        PLATFORM + "/events?conversationKey=" + CONV_KEY,
        headers={
            "X-Session-Token": tok,
            "Vellum-Organization-Id": ORG_ID,
            "Accept": "text/event-stream",
        },
    )
    return urllib.request.urlopen(req, timeout=60)


def build_content(body):
    """Plain message, plus page context when the Chrome extension sends it."""
    parts = []
    if body.get("voice"):
        parts.append("[Voice message through the notch. Your reply will be read aloud: "
                     "answer in 1-3 short conversational sentences. No lists, no markdown, "
                     "no links, no emoji.]")
    else:
        parts.append("[Notch chat, tiny screen. Keep it short and plain-text.]")
    page = body.get("page") or {}
    if page.get("title") or page.get("url") or page.get("selection"):
        parts.append("[Page the user is on]")
        if page.get("title"):
            parts.append("Title: " + str(page["title"]))
        if page.get("url"):
            parts.append("URL: " + str(page["url"]))
        if page.get("selection"):
            parts.append("Selected text: " + str(page["selection"])[:2000])
        parts.append("")
    parts.append(str(body.get("message", "")))
    return "\n".join(parts)


def send_message(content):
    sent = platform_call("/messages/", {
        "conversationKey": CONV_KEY,
        "content": content,
        "conversationType": "standard",
        "sourceChannel": "vellum",
        "interface": "macos",
    })
    if not sent.get("conversationId"):
        raise RuntimeError("send not accepted: " + json.dumps(sent)[:200])
    return sent["conversationId"]


_SENTENCE_RE = re.compile(r"(.+?[.!?\u2026])(?:\s+|$)", re.S)


def stream_inference(body, emit):
    """Stream the brain's reply. Calls emit(dict) for each NDJSON frame:
    {"type":"delta","text":...}, {"type":"audio","b64":...},
    {"type":"done","reply":...}."""
    voice = bool(body.get("voice"))
    content = build_content(body)

    es = open_event_stream()
    try:
        conv_id = send_message(content)

        full = []          # all delta text
        unspoken = ""      # text not yet sent to TTS
        first_audio = True
        working_sent = False
        deadline = time.time() + STREAM_TIMEOUT

        def speak(chunk):
            nonlocal first_audio
            if not voice:
                return
            b64 = tts(chunk, pad=first_audio)
            if b64:
                emit({"type": "audio", "b64": b64})
                first_audio = False

        for raw in es:
            if time.time() > deadline:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data:"):
                continue
            try:
                evt = json.loads(line[5:].strip())
            except Exception:
                continue
            msg = evt.get("message") or {}
            mtype = msg.get("type")
            mcid = msg.get("conversationId") or evt.get("conversationId")
            if mcid and mcid != conv_id:
                continue

            if mtype == "tool_use_start" and not working_sent:
                # the assistant picked up actual work (tool use), not just chatting
                working_sent = True
                emit({"type": "working"})
            elif mtype == "assistant_text_delta":
                text = msg.get("text") or ""
                if not text:
                    continue
                full.append(text)
                emit({"type": "delta", "text": text})
                unspoken += text
                # peel off complete sentences and voice them right away
                while True:
                    m = _SENTENCE_RE.match(unspoken.lstrip())
                    if not m:
                        break
                    sentence = m.group(1).strip()
                    unspoken = unspoken.lstrip()[m.end():]
                    if len(strip_for_tts(sentence)) >= 2:
                        speak(sentence)
            elif mtype == "message_complete":
                tail = unspoken.strip()
                if tail and len(strip_for_tts(tail)) >= 2:
                    speak(tail)
                reply = "".join(full).strip()
                if reply:
                    emit({"type": "done", "reply": reply})
                    return
                # turn produced no text (tool-only turn); keep listening
                deadline = time.time() + 30

        reply = "".join(full).strip()
        if reply:
            tail = unspoken.strip()
            if tail and len(strip_for_tts(tail)) >= 2:
                speak(tail)
            emit({"type": "done", "reply": reply})
        else:
            emit({"type": "error", "error": "Assistant took too long. Try again."})
    finally:
        try:
            es.close()
        except Exception:
            pass


# --- Classic request/response path (Chrome extension) ----------------------

def _assistant_snapshot(conv_id):
    if not conv_id:
        return {}
    data = platform_call("/messages/?conversationId=%s&page=latest&limit=30" % conv_id)
    return {m["id"]: len(m.get("content") or "")
            for m in data.get("messages", []) if m.get("role") == "assistant"}


def _known_conv_id():
    try:
        with open(os.path.join(HERE, "conv_id.txt")) as f:
            return f.read().strip()
    except Exception:
        return None


_baseline_cache = {"conv_id": None, "snap": None, "ts": 0.0}


def run_inference(body):
    content = build_content(body)
    conv_id = _known_conv_id()
    c = _baseline_cache
    if c["snap"] is not None and c["conv_id"] == conv_id and time.time() - c["ts"] < 120:
        baseline = c["snap"]
    else:
        baseline = _assistant_snapshot(conv_id)

    new_conv_id = send_message(content)
    if new_conv_id != conv_id:
        conv_id = new_conv_id
        try:
            with open(os.path.join(HERE, "conv_id.txt"), "w") as f:
                f.write(conv_id)
        except Exception:
            pass
        baseline = {}

    deadline = time.time() + POLL_TIMEOUT
    while time.time() < deadline:
        time.sleep(POLL_INTERVAL)
        data = platform_call("/messages/?conversationId=%s&page=latest&limit=30" % conv_id)
        new_parts = []
        for m in data.get("messages", []):
            if m.get("role") != "assistant":
                continue
            text = m.get("content") or ""
            if not text.strip():
                continue
            prev_len = baseline.get(m["id"])
            if prev_len is None:
                new_parts.append(text)
            elif len(text) > prev_len:
                new_parts.append(text[prev_len:])
        if new_parts:
            _baseline_cache.update({
                "conv_id": conv_id,
                "snap": {m["id"]: len(m.get("content") or "")
                         for m in data.get("messages", []) if m.get("role") == "assistant"},
                "ts": time.time(),
            })
            return "\n\n".join(p.strip() for p in new_parts if p.strip())
    raise TimeoutError("Assistant took too long. Try again.")


class Handler(BaseHTTPRequestHandler):
    def _cors(self):
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        self.send_response(200)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "service": "dynamic-notch-relay", "brain": "cloud", "streaming": True}).encode())

    def _json(self, payload, code=200):
        self.send_response(code)
        self._cors()
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode())

    def do_POST(self):
        try:
            n = int(self.headers.get("Content-Length", 0))
            body = json.loads(self.rfile.read(n) or b"{}")
        except Exception:
            body = {}

        path = self.path.rstrip("/")

        if path.endswith("tts"):
            try:
                audio = tts(str(body.get("text", "")))
                payload = {"ok": bool(audio), "audio": audio} if audio else {"ok": False, "error": "no tts key"}
            except Exception as e:
                payload = {"ok": False, "error": "tts error: " + str(e)}
            self._json(payload)
            return

        if path.endswith("chat-stream"):
            self.send_response(200)
            self._cors()
            self.send_header("Content-Type", "application/x-ndjson")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()

            def emit(frame):
                self.wfile.write((json.dumps(frame) + "\n").encode())
                self.wfile.flush()

            try:
                stream_inference(body, emit)
            except urllib.error.HTTPError as e:
                err = ("session token expired, drop a fresh one in ~/.dynamic-notch/session_token.txt"
                       if e.code in (401, 403) else "platform error %s" % e.code)
                try:
                    emit({"type": "error", "error": err})
                except Exception:
                    pass
            except (BrokenPipeError, ConnectionResetError):
                pass
            except Exception as e:
                try:
                    emit({"type": "error", "error": "relay error: " + str(e)})
                except Exception:
                    pass
            return

        # classic /chat
        try:
            reply = run_inference(body)
            payload, code = {"ok": True, "reply": reply}, 200
        except TimeoutError as e:
            payload, code = {"ok": False, "error": str(e)}, 504
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                payload = {"ok": False, "error": "session token expired, drop a fresh one in ~/.dynamic-notch/session_token.txt"}
            else:
                payload = {"ok": False, "error": "platform error %s" % e.code}
            code = 502
        except Exception as e:
            payload, code = {"ok": False, "error": "relay error: " + str(e)}, 500
        self._json(payload, code)

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
