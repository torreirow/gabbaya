# OIDC single sign-on E2E test

Tests patch `0004-oidc-sso` end to end against a mock OpenID Connect provider
([navikt/mock-oauth2-server](https://github.com/navikt/mock-oauth2-server)).

```bash
docker build -t gabbaya:test --build-arg INVOICEPLANE_VERSION=$(cat UPSTREAM_VERSION) \
  --build-arg INVOICEPLANE_SHA256=$(cat UPSTREAM_SHA256) .
tests/oidc-e2e/run.sh gabbaya:test        # DOCKER="sudo docker" if needed
```

`run.sh` starts MariaDB, the mock provider and the image on a private Docker network (no host
ports), installs InvoicePlane with the CLI installer and plays these scenarios with `browser.py`
(a minimal cookie-aware client that follows redirects one by one):

| Area           | Checks                                                                         |
| -------------- | ------------------------------------------------------------------------------ |
| Setup          | migration adds `user_auth_provider` and `user_oidc_sub`                        |
| Login page     | SSO button + local form; authorization request with PKCE S256, state, nonce    |
| Single sign-on | auto-redirect → provider → callback → dashboard in one visit; link by verified email; linked subject survives an email change; logout → `?local=1` without redirect |
| Refusals       | unverified email, unknown user (auto-create off), inactive account, forged callback |
| Rate limiting  | failed SSO attempts count towards `LOGIN_IP_MAX_ATTEMPTS`                      |
| Local login    | `?local=1` fallback; account without local password fails cleanly but can use SSO; local login disabled hides the form and refuses posts |

The mock issues claims per token request (`grant_type=authorization_code`), so each scenario
restarts it with the identity it needs.
