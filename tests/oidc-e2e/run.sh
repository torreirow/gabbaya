#!/usr/bin/env bash
# End-to-end test of OIDC single sign-on (patch 0004) against a mock OpenID Connect provider.
#
# Starts MariaDB, navikt/mock-oauth2-server and the given Gabbaya image on a private Docker
# network, installs InvoicePlane via the CLI installer and plays the login scenarios with a
# minimal cookie-aware browser. No host ports are published.
#
# Usage: tests/oidc-e2e/run.sh [image]        (default: gabbaya:test)
set -euo pipefail

IMAGE="${1:-gabbaya:test}"
HERE="$(cd "$(dirname "$0")" && pwd)"
ID="oidc-e2e-$$"
NET="${ID}"
MOCK_IMAGE="ghcr.io/navikt/mock-oauth2-server:2.1.10"
PY_IMAGE="python:3.12-alpine"
DOCKER="${DOCKER:-docker}"
FAILED=0

cleanup() {
    ${DOCKER} rm -f "${ID}-ip" "${ID}-db" "${ID}-mock" >/dev/null 2>&1 || true
    ${DOCKER} network rm "${NET}" >/dev/null 2>&1 || true
    rm -f "${HERE}"/jar-*.txt
}
trap cleanup EXIT

sql() { ${DOCKER} exec "${ID}-db" mariadb -uroot -proot ip -Nse "$1"; }

browser() {
    ${DOCKER} run --rm --network "${NET}" -v "${HERE}:/work" -w /work "${PY_IMAGE}" python3 /work/browser.py "$@"
}

# check <description> <json> <python expression over d>
check() {
    if python3 -c 'import json,sys; d=json.loads(sys.argv[1]); sys.exit(0 if eval(sys.argv[2]) else 1)' "$2" "$3"; then
        echo "  PASS  $1"
    else
        echo "  FAIL  $1"
        echo "        got: $2"
        FAILED=$((FAILED + 1))
    fi
}

mock() { # <sub> <email> <email_verified>
    local config
    config=$(cat <<EOF
{"interactiveLogin": false, "httpServer": "NettyWrapper",
 "tokenCallbacks": [{"issuerId": "default", "tokenExpiry": 300,
   "requestMappings": [{"requestParam": "grant_type", "match": "authorization_code",
     "claims": {"sub": "$1", "email": "$2", "email_verified": $3,
                "name": "E2E User", "aud": ["invoiceplane"]}}]}]}
EOF
)
    ${DOCKER} rm -f "${ID}-mock" >/dev/null 2>&1 || true
    ${DOCKER} run -d --name "${ID}-mock" --network "${NET}" --network-alias mock \
        -e SERVER_PORT=8080 -e JSON_CONFIG="${config}" "${MOCK_IMAGE}" >/dev/null
    for _ in $(seq 1 60); do
        ${DOCKER} exec "${ID}-ip" curl -sf http://mock:8080/default/.well-known/openid-configuration >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo "mock provider did not start" >&2
    exit 1
}

reset_rate_limit() { sql "DELETE FROM ip_login_log WHERE login_name LIKE 'login_ip:%'"; }

setting() { sql "INSERT INTO ip_settings (setting_key, setting_value) VALUES ('$1', '$2') ON DUPLICATE KEY UPDATE setting_value = '$2'"; }

echo "== setup (${IMAGE})"
${DOCKER} network create "${NET}" >/dev/null
${DOCKER} run -d --name "${ID}-db" --network "${NET}" --network-alias db \
    -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=ip -e MARIADB_USER=ip -e MARIADB_PASSWORD=ip \
    mariadb:11 >/dev/null
for _ in $(seq 1 60); do
    ${DOCKER} exec "${ID}-db" mariadb -uip -pip -e 'SELECT 1' ip >/dev/null 2>&1 && break
    sleep 1
done

PASSWORD="e2e-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
${DOCKER} run -d --name "${ID}-ip" --network "${NET}" --network-alias ip \
    -e IP_URL=http://ip -e REMOVE_INDEXPHP=true \
    -e DB_HOSTNAME=db -e DB_USERNAME=ip -e DB_PASSWORD=ip -e DB_DATABASE=ip -e DB_PORT=3306 \
    -e IP_DB_HOSTNAME=db -e IP_DB_USERNAME=ip -e IP_DB_PASSWORD=ip -e IP_DB_DATABASE=ip \
    -e ENCRYPTION_KEY="base64:$(head -c 32 /dev/urandom | base64)" -e ENCRYPTION_CIPHER=AES-256 \
    -e SETUP_COMPLETED=true -e DISABLE_SETUP=true \
    -e DEFAULT_ADMIN_EMAIL=admin@example.com -e DEFAULT_ADMIN_NAME=Admin -e DEFAULT_ADMIN_PASSWORD="${PASSWORD}" \
    -e OIDC_ENABLED=true -e OIDC_PROVIDER_URL=http://mock:8080/default \
    -e OIDC_CLIENT_ID=invoiceplane -e OIDC_CLIENT_SECRET=e2e-secret \
    -e LOGIN_IP_MAX_ATTEMPTS=4 \
    "${IMAGE}" >/dev/null
for _ in $(seq 1 60); do
    ${DOCKER} exec "${ID}-ip" curl -s -o /dev/null -w '%{http_code}' http://localhost/ 2>/dev/null | grep -qE '200|30[237]' && break
    sleep 1
done
${DOCKER} exec -w /var/www/html "${ID}-ip" php index.php setup cli migrate >/dev/null
${DOCKER} exec -w /var/www/html "${ID}-ip" php index.php setup cli create_default_user >/dev/null
sql "INSERT INTO ip_users (user_type, user_active, user_email, user_name, user_password, user_psalt, user_language, user_date_created, user_date_modified)
     VALUES (1, 1, 'guest@example.com', 'SSO only', NULL, NULL, 'system', NOW(), NOW())"
check "migration created the OIDC columns" "{\"n\": $(sql "SELECT COUNT(*) FROM information_schema.columns WHERE table_schema='ip' AND table_name='ip_users' AND column_name IN ('user_auth_provider','user_oidc_sub')")}" 'd["n"] == 2'

mock admin-sub admin@example.com true

echo "== login page and authorization request"
r=$(browser visit s1)
check "without auto-redirect the login page shows SSO button and local form" "$r" 'd["final"] == 200 and d["sso_button"] and d["local_form"] and not d["logged_in"]'
r=$(browser authorize-params s2)
check "authorization request uses code flow with PKCE S256, state and nonce" "$r" 'd["status"] == 302 and d["params"]["response_type"] == "code" and d["params"]["code_challenge_method"] == "S256" and d["has_code_challenge"] and d["params"]["state"] and d["params"]["nonce"]'

echo "== single sign-on"
setting oidc_auto_redirect_login 1
r=$(browser visit s3)
check "one visit with a provider session ends logged in on the dashboard" "$r" 'd["logged_in"] and d["chain"][-1].endswith("ip/dashboard") and any("mock:8080" in c for c in d["chain"])'
check "first login links the account by verified email" "{\"sub\": \"$(sql "SELECT user_oidc_sub FROM ip_users WHERE user_email='admin@example.com'")\"}" 'd["sub"] == "admin-sub"'
r=$(browser page s3 sessions/logout)
check "logout returns to the local login page without redirecting to the provider" "$r" 'd["chain"][-1].endswith("ip/sessions/login?local=1") and d["local_form"] and not any("mock" in c for c in d["chain"])'

mock admin-sub changed@example.com true
r=$(browser visit s4)
check "a linked subject logs in even when the provider email changed" "$r" 'd["logged_in"]'

echo "== refusals"
mock guest-sub guest@example.com false
r=$(browser visit s5)
check "unverified email is not linked and shows the local fallback" "$r" 'not d["logged_in"] and d["error"] and d["local_form"] and d["chain"][-1].endswith("login?local=1")'
mock nobody-sub nobody@example.com true
r=$(browser visit s6)
check "unknown user is refused when auto-create is off" "$r" 'not d["logged_in"] and "No account" in d["error"]'
sql "UPDATE ip_users SET user_active = 0 WHERE user_email = 'guest@example.com'"
mock guest-sub guest@example.com true
r=$(browser visit s7)
check "inactive account is refused" "$r" 'not d["logged_in"] and "inactive" in d["error"]'
sql "UPDATE ip_users SET user_active = 1 WHERE user_email = 'guest@example.com'"
r=$(browser tampered-callback s8)
check "forged code/state is refused without a server error" "$r" 'not d["logged_in"] and d["error"] and not d["http_500"]'

echo "== rate limiting"
mock admin-sub admin@example.com true
r=$(browser visit s9)
check "after 4 failures from this IP even a valid SSO login is refused" "$r" 'not d["logged_in"]'
reset_rate_limit
r=$(browser visit s10)
check "after the window resets SSO works again" "$r" 'd["logged_in"]'

echo "== local login"
reset_rate_limit
r=$(browser local-login s11 admin@example.com "${PASSWORD}" "sessions/login?local=1")
check "local password login works via ?local=1" "$r" 'd["logged_in"] and not d["http_500"]'
r=$(browser local-login s12 guest@example.com anything "sessions/login?local=1")
check "account without local password fails cleanly" "$r" 'not d["logged_in"] and not d["http_500"]'
mock guest-sub guest@example.com true
reset_rate_limit
r=$(browser visit s13)
check "account without local password can log in through SSO" "$r" 'd["logged_in"]'
setting oidc_allow_local_login 0
r=$(browser page s14 "sessions/login?local=1")
check "with local login disabled the form is hidden" "$r" 'not d["local_form"] and d["sso_button"]'
r=$(browser local-login s15 admin@example.com "${PASSWORD}" "sessions/login?local=1" sessions/passwordreset)
check "with local login disabled a valid password post is refused" "$r" 'not d["logged_in"]'

echo
if [ "${FAILED}" -eq 0 ]; then
    echo "OIDC E2E: all checks passed"
else
    echo "OIDC E2E: ${FAILED} check(s) failed"
    exit 1
fi
