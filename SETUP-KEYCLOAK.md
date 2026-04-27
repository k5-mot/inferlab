# Keycloak Initial Setup

This document describes the initial setup flow for Keycloak used by this repository.

## 1. Start required containers

Run services including `common` and `openwebui` profiles.

```bash
sudo docker compose \
  --profile common \
  --profile inference-ollama \
  --profile openwebui \
  up -d --force-recreate --remove-orphans
```

Verify Keycloak is up:

```bash
sudo docker ps | grep inferlab-keycloak
```

## 2. Open Keycloak Admin Console

Open:

- `http://192.168.3.10:30000/admin/master/console/`

Login with bootstrap admin (master realm):

- Username: `admin`
- Password: `admin`

Notes:

- Bootstrap admin is for administration tasks.
- Open WebUI login uses the `inferlab` realm, not `master`.

## 3. Confirm realm and client

Target realm is `inferlab`.

Open client settings in Keycloak:

- Realm: `inferlab`
- Client: `open-webui`

Required values:

- `Client authentication`: ON (confidential client)
- `Standard flow`: ON
- Redirect URIs includes:
  - `http://localhost:31001/oauth/oidc/callback`
  - `http://192.168.3.10:31001/oauth/oidc/callback`
- Web origins includes:
  - `http://localhost:31001`
  - `http://192.168.3.10:31001`

## 4. Create first login user for inferlab realm

If no users exist in `inferlab`, Open WebUI login stops with credential errors.

Create a user in `inferlab` realm (example):

- Username: `owui`
- Enabled: ON
- Email verified: ON
- Set password: `OwuiPass123!`
- Temporary password: OFF

Recommended: also clear any required actions (profile update, password update, etc.) for the first user.

## 5. Verify Open WebUI OIDC endpoints

In compose config, Open WebUI should use public Keycloak URL for browser flow:

- `OPENID_PROVIDER_URL=http://192.168.3.10:30000/realms/inferlab/.well-known/openid-configuration`
- `OPENID_REDIRECT_URI=http://192.168.3.10:31001/oauth/oidc/callback`
- `WEBUI_URL=http://192.168.3.10:31001`

Apply container changes:

```bash
sudo docker compose \
  --profile common \
  --profile inference-ollama \
  --profile openwebui \
  up -d --force-recreate open-webui
```

## 6. Login test flow

1. Open `http://192.168.3.10:31001/auth?redirect=%2F`
2. Click `Continue with Keycloak`
3. Confirm redirect target starts with:
   - `http://192.168.3.10:30000/realms/inferlab/protocol/openid-connect/auth`
4. Login using the user created in step 4

## 7. Troubleshooting

### A. `Timeout when waiting for 3rd party check iframe message`

Check Keycloak hostname and access host consistency:

- Access Keycloak and Open WebUI with the same host/IP (`192.168.3.10`)
- Avoid mixing `localhost` and LAN IP in the same browser session

### B. Redirect goes to `http://keycloak:8080/...`

Cause: browser-facing provider URL is incorrectly set to container-internal hostname.

Fix: ensure Open WebUI uses:

- `OPENID_PROVIDER_URL=http://192.168.3.10:30000/realms/inferlab/.well-known/openid-configuration`

### C. `The email or password provided is incorrect`

Typical causes:

- User does not exist in `inferlab` realm
- Password is temporary
- Required actions remain on the user
- User is disabled

### D. `Account is not fully set up`

User needs setup completion.

Fix for the user:

- Set non-temporary password
- Clear required actions
- Ensure `enabled=true` and `emailVerified=true`

## 8. Operational note

`realm-export.json` currently defines realms/clients but does not include users.

Therefore, user creation for `inferlab` realm is required after first deployment.
