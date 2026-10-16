#!/usr/bin/env python3
"""Minimal browser for the OIDC E2E test: cookies, manual redirects, CSRF-aware forms.

Usage: browser.py <scenario> [args]   (state kept in /work/jar-<name>.txt)
Prints one JSON line with the observed result.
"""
import http.cookiejar
import json
import re
import sys
import urllib.parse
import urllib.request

BASE = "http://ip"


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def opener(jar_name):
    jar = http.cookiejar.MozillaCookieJar(f"/work/jar-{jar_name}.txt")
    try:
        jar.load(ignore_discard=True, ignore_expires=True)
    except FileNotFoundError:
        pass
    o = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar), NoRedirect)
    return o, jar


def fetch(o, url, data=None):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode() if data is not None else None)
    try:
        r = o.open(req, timeout=20)
        return r.status, r.headers, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.headers, e.read().decode("utf-8", "replace")


def follow(o, url, data=None, max_hops=10):
    """Follow redirects, returning the chain of (status, url) and the final body."""
    chain = []
    status, headers, body = fetch(o, url, data)
    chain.append((status, url))
    while status in (301, 302, 303, 307) and len(chain) < max_hops:
        url = urllib.parse.urljoin(url, headers["Location"])
        status, headers, body = fetch(o, url)
        chain.append((status, url))
    return chain, body


def csrf(body):
    m = re.search(r'name="_ip_csrf" value="([^"]+)"', body)
    return m.group(1) if m else ""


def flash(body):
    """Flash error messages rendered by layout/alerts (role="alert", dismissible)."""
    m = re.search(r'alert-danger alert-dismissible" role="alert">.*?<span>(.*?)</span>', body, re.S)
    return re.sub(r"<[^>]+>|\s+", " ", m.group(1)).strip() if m else ""


def short(chain):
    return [f"{s} {urllib.parse.urlsplit(u).netloc}{urllib.parse.urlsplit(u).path}"
            + (f"?{urllib.parse.urlsplit(u).query[:60]}" if urllib.parse.urlsplit(u).query else "")
            for s, u in chain]


def main():
    scenario = sys.argv[1]
    jar_name = sys.argv[2] if len(sys.argv) > 2 else "default"
    o, jar = opener(jar_name)
    out = {"scenario": scenario}

    if scenario == "wizard":
        for step, data in (("language", {"ip_lang": "english"}), ("prerequisites", {}), ("configure_database", {})):
            _, _, page = fetch(o, f"{BASE}/setup/{step}")
            st, _, _ = fetch(o, f"{BASE}/setup/{step}", {"_ip_csrf": csrf(page), "btn_continue": "Continue", **data})
            out[step] = st
        _, _, page = fetch(o, f"{BASE}/setup/upgrade_tables")
        out["upgrade"] = "successfully upgraded" in page

    elif scenario == "visit":
        # Anonymous visit of the login page (auto-redirect expected when enabled)
        chain, body = follow(o, f"{BASE}/sessions/login")
        out["chain"] = short(chain)
        out["final"] = chain[-1][0]
        out["logged_in"] = "sessions/logout" in body
        out["error"] = flash(body)
        out["local_form"] = 'name="password"' in body
        out["sso_button"] = "sessions/oidc_login" in body

    elif scenario == "page":
        chain, body = follow(o, f"{BASE}/{sys.argv[3]}")
        out["chain"] = short(chain)
        out["final"] = chain[-1][0]
        out["logged_in"] = "sessions/logout" in body
        out["error"] = flash(body)
        out["local_form"] = 'name="password"' in body
        out["sso_button"] = "sessions/oidc_login" in body

    elif scenario == "authorize-params":
        status, headers, _ = fetch(o, f"{BASE}/sessions/oidc_login")
        q = urllib.parse.parse_qs(urllib.parse.urlsplit(headers.get("Location", "")).query)
        out["status"] = status
        out["params"] = {k: q.get(k, [""])[0][:12] for k in ("response_type", "client_id", "scope", "code_challenge_method", "state", "nonce", "redirect_uri")}
        out["has_code_challenge"] = bool(q.get("code_challenge"))

    elif scenario == "tampered-callback":
        chain, body = follow(o, f"{BASE}/sessions/oidc_callback?code=forged&state=forged")
        out["chain"] = short(chain)
        out["logged_in"] = "sessions/logout" in body
        out["error"] = flash(body)
        out["http_500"] = any(s >= 500 for s, _ in chain)

    elif scenario == "local-login":
        email, password, path = sys.argv[3], sys.argv[4], sys.argv[5]
        token_page = sys.argv[6] if len(sys.argv) > 6 else path
        _, _, page = fetch(o, f"{BASE}/{token_page}")
        chain, body = follow(o, f"{BASE}/{path}", {"_ip_csrf": csrf(page), "email": email, "password": password, "btn_login": "true"})
        out["chain"] = short(chain)
        out["logged_in"] = "sessions/logout" in body
        out["error"] = flash(body)
        out["http_500"] = any(s >= 500 for s, _ in chain)

    jar.save(ignore_discard=True, ignore_expires=True)
    print(json.dumps(out))


main()
