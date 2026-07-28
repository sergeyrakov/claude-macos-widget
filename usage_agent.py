#!/usr/bin/env python3
"""
Read-only usage agent for the Claude Usage menu-bar widget.

Borrows the Claude Code CLI's existing access token from the Keychain
("Claude Code-credentials") and calls /api/oauth/usage. It NEVER refreshes or
writes any token, so it can never disturb the CLI's login or trigger rotation.

Emits a single compact JSON line the Swift widget consumes:

  {
    "ok": bool,               # true if we have live numbers this run
    "stale": bool,            # true if numbers are from cache (token expired)
    "reason": "...",          # when ok=false and no cache
    "plan": "max|pro|team|…", # subscriptionType from the CLI keychain (may be null)
    "fetched_at": <epoch s>,  # when the cached/live numbers were fetched
    "limits": [               # normalized from the API's limits[] array
       {"kind": "...", "label": "5-hour session", "short": "5h",
        "percent": <0-100>, "severity": "normal|warning|...",
        "resets_at": "<ISO>", "is_active": bool}
    ],
    "credits": {"used": <float>, "limit": <float>, "percent": <int>}  # extra-usage credits
  }
"""
import json, os, subprocess, sys, time

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
CLI_SVC   = "Claude Code-credentials"
CFG_DIR   = os.path.expanduser("~/.config/claude-usage-widget")
CACHE     = os.path.join(CFG_DIR, "last_usage.json")
UA        = "claude-usage-widget/1.0"

def label_for(lim):
    """Human label + short tag for a limit entry from the API's limits[] array."""
    kind = lim.get("kind", "")
    scope = lim.get("scope") or {}
    model = ((scope.get("model") or {}).get("display_name")) if isinstance(scope, dict) else None
    if kind == "session":
        return "5-hour session", "5h"
    if kind == "weekly_all":
        return "7-day (all models)", "7d"
    if kind == "weekly_scoped":
        m = model or "scoped"
        return f"7-day ({m})", m
    # sensible fallback
    grp = lim.get("group", kind or "limit")
    return kind.replace("_", " ").title() or grp, (model or grp)[:6]


def read_cli_token():
    try:
        raw = subprocess.check_output(
            ["security", "find-generic-password", "-s", CLI_SVC, "-w"],
            stderr=subprocess.DEVNULL).decode()
        o = json.loads(raw)["claudeAiOauth"]
        return o.get("accessToken"), o.get("expiresAt", 0), o.get("subscriptionType")
    except Exception:
        return None, 0, None


def http_get(url, headers):
    cmd = ["curl", "-s", "--max-time", "25", url]
    for k, v in headers.items():
        cmd += ["-H", f"{k}: {v}"]
    out = subprocess.check_output(cmd).decode().strip()
    return json.loads(out) if out else None


def norm_pct(v):
    """Accept a percent (0..100) or fraction (0..1); return a 0..100 float."""
    if v is None:
        return None
    try:
        v = float(v)
    except (TypeError, ValueError):
        return None
    return v * 100.0 if 0 < v <= 1.0 else v


def extract_limits(resp):
    """Normalize the API's limits[] array; fall back to window keys if absent."""
    out = []
    limits = resp.get("limits")
    if isinstance(limits, list):
        for lim in limits:
            if not isinstance(lim, dict):
                continue
            pct = norm_pct(lim.get("percent", lim.get("utilization")))
            if pct is None:
                continue
            label, short = label_for(lim)
            out.append({
                "kind": lim.get("kind", ""),
                "label": label, "short": short,
                "percent": pct,
                "severity": lim.get("severity", "normal"),
                "resets_at": lim.get("resets_at", lim.get("reset_at")),
                "is_active": bool(lim.get("is_active", False)),
            })
    else:
        for key in ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]:
            node = resp.get(key)
            if not isinstance(node, dict):
                continue
            pct = norm_pct(node.get("utilization"))
            if pct is None:
                continue
            short = {"five_hour": "5h", "seven_day": "7d"}.get(key, key)
            out.append({"kind": key, "label": key.replace("_", " "), "short": short,
                        "percent": pct, "severity": "normal",
                        "resets_at": node.get("resets_at"), "is_active": False})
    return out


def extract_credits(resp):
    spend = resp.get("spend")
    if isinstance(spend, dict) and isinstance(spend.get("limit"), dict):
        used = spend.get("used", {}).get("amount_minor", 0)
        lim = spend.get("limit", {}).get("amount_minor", 0)
        exp = spend.get("limit", {}).get("exponent", 2)
        div = 10 ** exp
        return {"used": used / div, "limit": lim / div, "percent": spend.get("percent", 0)}
    return None


def load_cache():
    try:
        with open(CACHE) as f:
            return json.load(f)
    except Exception:
        return None


def save_cache(payload):
    os.makedirs(CFG_DIR, exist_ok=True)
    with open(CACHE, "w") as f:
        json.dump(payload, f)


def serve_cache(reason, auth_expired=False, transient=False, plan=None):
    """Emit the last-good cached numbers (if any), tagged with why we couldn't
    fetch. auth_expired => genuinely signed out (UI should dim). transient =>
    token is fine but the fetch failed, e.g. 429 (UI should KEEP the colors)."""
    cached = load_cache() or {}
    out = dict(cached)
    out.update({"ok": False, "auth_expired": auth_expired,
                "transient": transient, "stale": auth_expired, "reason": reason,
                "plan": plan or cached.get("plan")})
    out.setdefault("limits", [])
    print(json.dumps(out))


def main():
    token, expires_at, plan = read_cli_token()
    now_ms = time.time() * 1000

    if not token:
        serve_cache("no_cli_token", auth_expired=True, plan=plan); return

    # Token expired -> don't refresh (read-only). Signed-out => dim.
    if expires_at - now_ms < 60_000:
        serve_cache("cli_token_expired", auth_expired=True, plan=plan); return

    # Live fetch.
    try:
        resp = http_get(USAGE_URL, {
            "Authorization": f"Bearer {token}",
            "anthropic-beta": "oauth-2025-04-20",
            "anthropic-version": "2023-06-01",
            "User-Agent": UA,
        })
    except Exception:
        serve_cache("http_error", transient=True, plan=plan); return

    # An error body (most commonly a 429 rate_limit_error) is TRANSIENT: the
    # token is valid and our cached numbers are only minutes old — keep colors.
    if not isinstance(resp, dict) or "error" in resp:
        rtype = resp.get("error", {}).get("type", "bad_response") if isinstance(resp, dict) else "bad_response"
        serve_cache(rtype, transient=True, plan=plan); return

    payload = {
        "ok": True, "auth_expired": False, "transient": False, "stale": False,
        "fetched_at": int(time.time()),
        "plan": plan,
        "limits": extract_limits(resp),
        "credits": extract_credits(resp),
    }
    save_cache(payload)
    print(json.dumps(payload))


if __name__ == "__main__":
    main()
