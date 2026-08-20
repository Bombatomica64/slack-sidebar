#!/usr/bin/env python3
"""Slack OAuth2 sign-in with a real local callback.

Runs the whole authorization code flow without anyone copying a code by hand:
starts a loopback listener on the app's registered redirect URL, opens the
browser, receives the callback, exchanges the code, and puts the resulting
tokens in the keyring.

Prints exactly one JSON object on stdout so the QML side can treat it like every
other slack.sh subcommand. Progress goes to stderr.

Slack classifies a loopback redirect as a non-web URI and demands PKCE (RFC
7636) for it, so the challenge/verifier pair is mandatory here, not optional.
"""

import base64
import hashlib
import json
import os
import secrets
import ssl
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

SERVICE = "slack-agents"
API = "https://slack.com/api"

USER_SCOPES = [
    "channels:history", "channels:read", "channels:write",
    "groups:history", "groups:read", "groups:write",
    "im:history", "im:read", "im:write",
    "mpim:history", "mpim:read", "mpim:write",
    "users:read", "chat:write", "reactions:write", "search:read", "emoji:read",
]

CACHE_DIR = os.path.join(
    os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache")), "noctalia-slack"
)

DONE_PAGE = b"""<!doctype html><html><head><meta charset="utf-8">
<title>Slack connected</title></head>
<body style="font-family:system-ui;background:#11112d;color:#f3edf7;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<div style="text-align:center">
<h2 style="margin:0 0 .4em">Connected</h2>
<p style="opacity:.7;margin:0">You can close this tab and go back to the sidebar.</p>
</div></body></html>"""

FAIL_PAGE = b"""<!doctype html><html><head><meta charset="utf-8">
<title>Slack sign-in failed</title></head>
<body style="font-family:system-ui;background:#11112d;color:#f3edf7;
display:flex;align-items:center;justify-content:center;height:100vh;margin:0">
<div style="text-align:center">
<h2 style="margin:0 0 .4em">Sign-in failed</h2>
<p style="opacity:.7;margin:0">Check the sidebar for the reason.</p>
</div></body></html>"""


def emit(obj):
    json.dump(obj, sys.stdout)
    sys.stdout.write("\n")
    sys.stdout.flush()


def die(message, **extra):
    emit({"ok": False, "error": message, **extra})
    sys.exit(0)


def log(message):
    print(message, file=sys.stderr, flush=True)


def keyring_get(account):
    try:
        out = subprocess.run(
            ["secret-tool", "lookup", "service", SERVICE, "account", account],
            capture_output=True, timeout=15,
        )
        return out.stdout.decode().strip() or None
    except (OSError, subprocess.SubprocessError):
        return None


def keyring_set(account, label, value):
    subprocess.run(
        ["secret-tool", "store", "--label=" + label, "service", SERVICE, "account", account],
        input=value.encode(), check=True, timeout=15,
    )


def post_form(url, fields):
    body = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(
        url, data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded; charset=utf-8"},
    )
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode())
    except urllib.error.URLError as exc:
        die("could not reach Slack: %s" % exc)
    except json.JSONDecodeError:
        die("unreadable response from Slack")


def get_json(url, token):
    request = urllib.request.Request(url, headers={"Authorization": "Bearer " + token})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return json.loads(response.read().decode())
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        die("could not verify the new token: %s" % exc)


def self_signed_cert():
    """Generate (once) a cert for the loopback listener.

    Only needed because Slack requires https for registered redirect URLs, so a
    localhost callback has to speak TLS. The browser will warn once; the cert
    never leaves this machine.
    """
    os.makedirs(CACHE_DIR, mode=0o700, exist_ok=True)
    cert = os.path.join(CACHE_DIR, "loopback-cert.pem")
    key = os.path.join(CACHE_DIR, "loopback-key.pem")
    if os.path.exists(cert) and os.path.exists(key):
        return cert, key
    try:
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-keyout", key, "-out", cert, "-days", "3650",
             "-subj", "/CN=localhost",
             "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1"],
            check=True, capture_output=True, timeout=60,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        die("could not create a certificate for the local callback: %s" % exc)
    os.chmod(key, 0o600)
    return cert, key


class Callback(BaseHTTPRequestHandler):
    result = {}
    done = threading.Event()

    def do_GET(self):
        query = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        code = query.get("code", [None])[0]
        state = query.get("state", [None])[0]
        error = query.get("error", [None])[0]

        if code or error:
            Callback.result = {"code": code, "state": state, "error": error}
            body = DONE_PAGE if code else FAIL_PAGE
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            Callback.done.set()
            return

        # Anything else (favicon, a stray probe) must not end the wait.
        self.send_response(404)
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    redirect = sys.argv[1] if len(sys.argv) > 1 else "https://localhost:3000"
    timeout = int(os.environ.get("SLACK_OAUTH_TIMEOUT", "180"))

    client_id = keyring_get("client-id")
    client_secret = keyring_get("client-secret")
    if not client_id or not client_secret:
        die("no app credentials stored — add the Client ID and Client Secret in the "
            "plugin settings first (Basic Information -> App Credentials in Slack)")

    parsed = urllib.parse.urlparse(redirect)
    if parsed.hostname not in ("localhost", "127.0.0.1"):
        die("the redirect must point at localhost so the plugin can receive the "
            "callback itself; %s cannot be listened on" % redirect)
    port = parsed.port or (443 if parsed.scheme == "https" else 80)

    verifier = base64.urlsafe_b64encode(os.urandom(48)).rstrip(b"=").decode()
    challenge = base64.urlsafe_b64encode(
        hashlib.sha256(verifier.encode()).digest()
    ).rstrip(b"=").decode()
    state = secrets.token_urlsafe(24)

    try:
        server = HTTPServer(("127.0.0.1", port), Callback)
    except OSError as exc:
        die("cannot listen on %s: %s" % (redirect, exc))

    if parsed.scheme == "https":
        cert, key = self_signed_cert()
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(cert, key)
        server.socket = context.wrap_socket(server.socket, server_side=True)

    authorize = "https://slack.com/oauth/v2/authorize?" + urllib.parse.urlencode({
        "client_id": client_id,
        "user_scope": ",".join(USER_SCOPES),
        "redirect_uri": redirect,
        "state": state,
        "code_challenge": challenge,
        "code_challenge_method": "S256",
    })

    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    log("listening on %s" % redirect)

    try:
        subprocess.Popen(["xdg-open", authorize],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        log("could not open a browser; visit: %s" % authorize)

    if not Callback.done.wait(timeout):
        server.shutdown()
        die("timed out after %ss waiting for the Slack callback" % timeout,
            authorizeUrl=authorize)
    server.shutdown()

    result = Callback.result
    if result.get("error"):
        die("Slack refused the authorization: %s" % result["error"])
    if result.get("state") != state:
        die("callback state did not match; the sign-in was not completed")

    log("exchanging the code")
    response = post_form(API + "/oauth.v2.access", {
        "client_id": client_id,
        "client_secret": client_secret,
        "code": result["code"],
        "code_verifier": verifier,
        "redirect_uri": redirect,
    })
    if not response.get("ok"):
        die("token exchange failed: %s" % response.get("error", "unknown error"))

    authed = response.get("authed_user") or {}
    token = authed.get("access_token") or response.get("access_token") or ""
    refresh = authed.get("refresh_token") or response.get("refresh_token") or ""
    expires = authed.get("expires_in") or response.get("expires_in") or 0
    if not token:
        die("Slack returned no user token; the app must request user scopes")

    who = get_json(API + "/auth.test", token)
    if not who.get("ok"):
        die("the new token failed auth.test: %s" % who.get("error", "unknown"))

    keyring_set("user-token", "Slack User Token", token)
    if refresh:
        keyring_set("user-refresh-token", "Slack User Refresh Token", refresh)

    rotating = token.startswith("xoxe.")
    emit({
        "ok": True,
        "user": who.get("user", ""),
        "userId": who.get("user_id", ""),
        "team": who.get("team", ""),
        "rotating": rotating,
        "refreshStored": bool(refresh),
        "expiresIn": expires,
        "scopes": authed.get("scope", ""),
    })


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        die("cancelled")
