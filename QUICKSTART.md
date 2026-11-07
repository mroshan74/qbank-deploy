# Quickstart — bring the server up from nothing

**Commands, in order, meant to be pasted one after another.** This is the path
back to a working app after an MVP round has been torn down. Everything here is
explained properly in [README.md](README.md); this file exists so you do not
have to read it again at 1am.

Every step is safe to re-run.

---

## 0. Preconditions

No commands. Confirm these are true before pasting anything:

- [ ] The box is provisioned and Docker works for your account: [INSTRUCTION.md](INSTRUCTION.md) steps 1-3, verified with `docker info`.
- [ ] `scripts/setup-app.sh` has been run once, so `/opt/qbank` exists, holds this repo, and has a filled-in `.env`.
- [ ] `docker login ghcr.io` has been done once on this account (the five GHCR packages are private).
- [ ] Every DNS A record (`HOMEPAGE_HOST` **and** `www.` under it, `ADMIN_HOST`, `LEARNER_HOST`, `WRITER_HOST`) resolves to this server.
- [ ] `API_TAG`, `WEB_TAG`, `LEARNER_TAG`, `WRITER_TAG` and `HOMEPAGE_TAG` in `.env` name **published** tags.
- [ ] **The database is empty.** Production runs on MongoDB Atlas, so there is no container to wipe and `down -v` clears nothing. Clear it in Atlas yourself. Nothing in this repo deletes data.

If any of those is not true, start from [README.md → Set up the application](README.md#set-up-the-application) instead.

---

## 1. Traefik

Owns the shared `traefik_proxy` network, so it goes first. Already running from a
previous round? Skip it, this stack is not torn down between rounds.

```bash
cd /opt/qbank
ACME_EMAIL=you@example.com docker compose -f compose.traefik.yml -p traefik up -d
```

Expect: `Container traefik  Started`.

---

## 2. The app stack

All five services together. Not `deploy.sh` — that deploys one service at a
time, and the frontends' readiness probes reach the api *through* their own
nginx, so starting a torn-down stack one tier at a time is slower for no gain.

```bash
docker compose -f compose.prod.yml -p qbank up -d
```

Expect: `qbank-api`, `qbank-admin`, `qbank-learner`, `qbank-writer` and
`qbank-homepage` started. Give the api ~30s, then:

```bash
docker compose -f compose.prod.yml -p qbank ps
```

Expect: `api` reaches `(healthy)`. Do not seed before it does.

---

## 3. Seed everything — one command

System organization, superadmin, taxonomy, then the 163 bundled exam papers and
their 14,868 questions. It runs inside the api image and talks to `api:5000` over
the internal network, so **you never sign in or call the API yourself**.

```bash
docker compose -f compose.prod.yml -p qbank --profile seed run --rm seed
```

Expect, on an empty database:

```
[seed] Creating the System organization and superadmin (skipped if present)...
[seed] Seeded the system organization (_id=6a71ad994b228f7bf76fb570).
[seed] Seeded superadmin: _id=6a71ad994b228f7bf76fb569, ...
[seed] Waiting for http://api:5000/api/readyz ...
[seed] API is ready.
[seed] Signed in as <SEED_SUPERADMIN_USERNAME>.
[seed] Seeding the taxonomy from the bundled file...
[seed] Taxonomy v1 is active: ...
[seed] Check: papers to create 163, already present 0, questions to add 14868, to refresh 0, not in the files 0.
[seed] Done. Papers created: 163, already present: 0, questions created: 14868, changed: 0, brought back: 0.
[seed] Sign in at https://<ADMIN_HOST> with "<SEED_SUPERADMIN_USERNAME>".
```

Run it again and every line reports a skip or a zero. That is the expected
outcome, not a failure. **Exception:** once reviewers have changed question
classifications in the admin app, a re-run puts the seed's classifications back
over theirs (`changed` is no longer zero). Do not re-run it on a database where
classification review has started.

If the content step fails with `Seed classifications were rejected before any
writes: Activate the matching bundled taxonomy...`, the database already has an
older taxonomy. Run it once with `SEED_TAXONOMY_FORCE=1` (below). Nothing was
written by the failed run.

If it fails with `The seed files changed after the classification manifest was
written (...)` or `The classification manifest predates the exam paper lock`,
the image carries seed files whose manifest was not re-hashed. That is fixed in
the API repo, not on the server: re-hash locally, commit, rebuild and deploy.

### The two overrides

Both are one-off, passed inline. Neither belongs in `.env`.

```bash
# add a taxonomy version even though the database already has one
# (also the fix for "Activate the matching bundled taxonomy")
docker compose -f compose.prod.yml -p qbank --profile seed \
  run --rm -e SEED_TAXONOMY_FORCE=1 seed

# import content even though the check found questions the seed files do not list
docker compose -f compose.prod.yml -p qbank --profile seed \
  run --rm -e SEED_FORCE=1 seed
```

`SEED_FORCE` exists for one case only: you added questions deliberately and want
to keep them. If you did not, the check is telling you the database predates
`_id` matching and importing would insert a second copy of all 14,868 rows. Clear
the database and start from step 3 instead.

---

## 4. Verify

```bash
# the three app tiers reach the api through their own /api proxy
docker compose -f compose.prod.yml -p qbank exec -T web     wget -q -O- http://127.0.0.1/api/readyz
docker compose -f compose.prod.yml -p qbank exec -T learner wget -q -O- http://127.0.0.1/api/readyz
docker compose -f compose.prod.yml -p qbank exec -T writer  wget -q -O- http://127.0.0.1/api/readyz
# the homepage has no /api; it answers its own health probe
docker compose -f compose.prod.yml -p qbank exec -T homepage wget -q -O- http://127.0.0.1/healthz
```

Expect: `{"status":"ok","database":"connected","buildId":"..."}` from each app tier, `ok` from the homepage.

```bash
# the PDF faces, including the one with spaces in its name
for svc in web learner; do
  docker compose -f compose.prod.yml -p qbank exec -T $svc \
    wget -S -q -O /dev/null "http://127.0.0.1/fonts/Century%20Schoolbook%20Std%20Regular.otf"
done

# a missing face must 404, never 200 with index.html
docker compose -f compose.prod.yml -p qbank exec -T web \
  wget -S -q -O /dev/null "http://127.0.0.1/fonts/no-such-face.otf"
```

Expect: `200 OK` with `Content-Type: font/otf` for the first, `404` for the second.
A 200 on the second means the `/fonts/` block is missing and every Malayalam
export will fail several layers away from the cause.

The writer ships its own, smaller set: `MANDARAM.ttf` and `NotoSansMalayalam.ttf`
only, no Century Schoolbook and no bold cut, so `Mandaram-Bold.ttf` is *meant*
to 404 there.

```bash
for face in MANDARAM.ttf NotoSansMalayalam.ttf; do
  docker compose -f compose.prod.yml -p qbank exec -T writer \
    wget -S -q -O /dev/null "http://127.0.0.1/fonts/$face"
done
```

Expect: `200 OK` with `Content-Type: font/ttf` for both.

Then in a browser:

- `https://<HOMEPAGE_HOST>` — the marketing site renders; `curl -sI https://www.<HOMEPAGE_HOST>/` answers `301` with a `Location:` on the apex; the Sign in to Studio link opens `https://<ADMIN_HOST>`.
- `https://<ADMIN_HOST>` — lands on `/login` (the root redirects there for a visitor); sign in as the seeded superadmin, set a new password when prompted, confirm the taxonomy page shows subjects and the exam papers list shows 163.
- `https://<LEARNER_HOST>` — sign in by mobile number, open a paper, download it, and confirm the Malayalam renders.
- `https://<WRITER_HOST>` — create a `writer` account in the admin and assign it a draft exam paper; sign in with it, open the paper, add a question, and confirm the Malayalam renders. Also check the writer's Malayalam face: `docker compose -f compose.prod.yml -p qbank exec -T writer wget -S -q -O /dev/null http://127.0.0.1/fonts/MANDARAM.ttf` answers `200` with `font/ttf`.

### Paper lifecycle audit (once, when the decision 0040 build first goes out)

Read-only report of published papers with no questions and stale question counts, run inside the api container so it uses that container's `MONGODB_URI`. Exit `0` means clean. `--apply` moves empty published papers back to draft and refreshes the counts. Details: `qbank-api/src/scripts/audit-paper-lifecycle.ts`.

```bash
docker compose -f compose.prod.yml -p qbank exec -T api node dist/scripts/audit-paper-lifecycle.js
docker compose -f compose.prod.yml -p qbank exec -T api node dist/scripts/audit-paper-lifecycle.js --apply
```

### Question bank backfill (once, when the decision 0042 build first goes out, and required)

Every question needs a `bank` (`pyq` or `external`) before the admin app can list it: each Question Bank page now asks for one bank, and a row from before the field matches neither, so an unbackfilled database shows **empty** Questions, My Questions and Review pages. Run it right after the new api image is up, inside the api container so it uses that container's `MONGODB_URI`. The first form only reports; `--apply` writes. It is safe to re-run, and rows the new build creates are stamped on write. Details: `qbank-api/src/scripts/backfill-question-banks.ts`.

```bash
docker compose -f compose.prod.yml -p qbank exec -T api node dist/scripts/backfill-question-banks.js
docker compose -f compose.prod.yml -p qbank exec -T api node dist/scripts/backfill-question-banks.js --apply
```

### Question source type migration (once, before the decision 0045 build serves traffic, and required)

The decision 0045 build accepts only three source types (`exam_paper`, `current_affairs`, `custom`). A question still carrying a retired one (`textbook`, `manual`, `editorial`, `user`) fails validation on its next save, and a learner export containing it fails. The script rewrites those to `custom`, deleted rows included.

Run it **from the new image before restarting the api**: pull, run it in a one-off container (the running api keeps serving, and it already accepts `custom`), then restart as in §5. The first form only reports; `--apply` writes. It is safe to re-run. Details: `qbank-api/src/scripts/migrate-question-source-types.ts`.

```bash
docker compose -f compose.prod.yml -p qbank pull api
docker compose -f compose.prod.yml -p qbank run --rm --no-deps api node dist/scripts/migrate-question-source-types.js
docker compose -f compose.prod.yml -p qbank run --rm --no-deps api node dist/scripts/migrate-question-source-types.js --apply
```

### The decision 0046 build (7th level)

The decision 0046 build adds `7th_level` and re-levels thirteen Last Grade Servants papers in the seed file, so re-run the seed step from §3 (it is idempotent) after the api is up. Then deploy the learner app and the admin app, in that order: both pin `examLevels` in their drift checks. There is no index or label migration: the database is seeded fresh, and the API ships the taxonomy it seeds.

---

## 5. Pull the latest build and restart everything

**This is the loop to use until the git pipelines are wired up.** Every push to
an app repo publishes `:latest` alongside its `:<short-sha>` tag, so pointing the
stack at `latest` and pulling is enough to pick up whatever was last built.

**One command does the whole thing:**

```bash
cd /opt/qbank
./scripts/deploy-latest.sh
```

Stop, pull, start, and prove all four nginx tiers answer. Add `--seed` to run the
step 3 bootstrap in the same pass, which is what you want after clearing the
database:

```bash
./scripts/deploy-latest.sh --seed
```

| Flag | Does |
|---|---|
| *(none)* | `down`, `pull`, `up -d`, then probe every nginx tier: `/api/readyz` through `web`, `learner` and `writer`, `/healthz` on `homepage` |
| `--seed` | also runs the seed profile once the api is answering |
| `--no-down` | skip the stop; compose recreates only services whose image changed, so an unchanged frontend is not bounced |
| `--tag <tag>` | use a pinned tag instead of `latest`, for all five services at once |
| `--help` | the summary above |

It refuses to touch anything if `.env` is missing a key that `.env.example` has,
the same check `deploy.sh` runs, and it takes the **same lock** as `deploy.sh` so
a refresh and a CI deploy cannot interleave.

### The same thing by hand

If you would rather not use the script, or want to see what it does:

```bash
cd /opt/qbank

# 1. point every service at the newest published image, and stamp a fresh
#    BUILD_ID so old sessions are retired the way a real deploy retires them
sed -i 's/^API_TAG=.*/API_TAG=latest/;s/^WEB_TAG=.*/WEB_TAG=latest/;s/^LEARNER_TAG=.*/LEARNER_TAG=latest/;s/^WRITER_TAG=.*/WRITER_TAG=latest/;s/^HOMEPAGE_TAG=.*/HOMEPAGE_TAG=latest/' .env
sed -i "s/^BUILD_ID=.*/BUILD_ID=$(date +%y%m%d%H%M)-latest/" .env

# 2. stop all app services
docker compose -f compose.prod.yml -p qbank down

# 3. pull the newest images
docker compose -f compose.prod.yml -p qbank pull

# 4. start everything again
docker compose -f compose.prod.yml -p qbank up -d
```

Step 1 only has to be run **once**; after that `.env` already says `latest` and
the loop is just steps 2 to 4. Re-stamping `BUILD_ID` each time is what signs out
sessions minted by the previous build, which a pinned-tag deploy gets for free.

Once the stack is up, re-run the seed if the database was cleared:

```bash
docker compose -f compose.prod.yml -p qbank --profile seed run --rm seed
```

> **Never add `-v` to that `down`.** It would delete the `ai_tagging_jobs`
> volume, and OpenAI batch jobs run for minutes to 24 hours with their artefacts
> on it. It is also **not** a way to reset data: the database is MongoDB Atlas,
> which no compose command touches. Clear that in Atlas.

> **`latest` is a testing convenience, not the deployment model.** While the tags
> say `latest` you cannot roll back, because `rollback.sh` works by redeploying a
> pinned tag and there is no record here of which build you are on. `docker
> compose -f compose.prod.yml -p qbank images` shows the image IDs you are
> actually running. When the pipelines land, go back to pinned short-SHA tags,
> which is what `deploy.sh` writes.

---

## 6. Once the git pipelines are wired up

CI then does all of the above on every push, and by hand it becomes:

```bash
cd /opt/qbank
./scripts/deploy.sh api     <sha>
./scripts/deploy.sh web     <sha>   # staff back office
./scripts/deploy.sh learner <sha>   # learner app
./scripts/deploy.sh writer  <sha>   # writer portal
./scripts/deploy.sh homepage <sha>  # marketing site
```

Roll back:

```bash
./scripts/rollback.sh api            # list the tags on this host
./scripts/rollback.sh api <old-sha>
```

---

## The same thing locally

The prod-parity stack, which brings its own MongoDB and needs no Traefik, DNS or
TLS. Use it to rehearse any of the above:

```bash
cd qbank-deploy
docker compose -f compose.local.yml down -v            # wipe the database
docker compose -f compose.local.yml up -d --build
docker compose -f compose.local.yml --profile seed run --rm seed
# → http://localhost:8080  (admin)
# → http://localhost:8081  (learner)
# → http://localhost:8082  (writer)
# → http://localhost:8083  (homepage)
```

---

## Adding a frontend tier to a running server

Once per new tier (the writer portal and the marketing site both arrive this
way; the worked example below is the writer's). **The order matters**: this
repo's `.env.example` names three new keys (`X_HOST`, `X_TAG`, `X_IMAGE`),
`deploy.sh` checks the server's `.env` against it after pulling this repo, and a
missing key stops **every** service's deploy, not just the new tier's.

1. **DNS:** point the new host (`WRITER_HOST`, `writer.qfoundry.in`) at this
   server and let it propagate. Let's Encrypt cannot issue the certificate until
   it does. For the homepage that is **two** records, the apex and `www.`, which
   share one certificate.
2. **`.env` first:** add the three keys, and, for an app tier, the new origin to
   `CLIENT_URL` (the homepage makes no API call and is not listed there):
   ```bash
   cd /opt/qbank
   cat >> .env <<'KEYS'
   WRITER_HOST=writer.qfoundry.in
   WRITER_TAG=latest
   WRITER_IMAGE=ghcr.io/mroshan74/qbank-writer
   KEYS
   nano .env   # append ,https://writer.qfoundry.in to CLIENT_URL
   ```
3. **GitHub:** in the new repo's settings set the four deploy secrets
   (`VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`, `VPS_SSH_KEY_PASSPHRASE`), the same
   values the other app repos use.
4. **Push this repo** (the new service, scripts and docs), then pull it here:
   `git -C /opt/qbank pull --ff-only`.
5. **First image:** push the new repo to `main`. CI lints, checks the env files
   and the copy, builds, publishes `ghcr.io/mroshan74/<repo>` and runs
   `deploy.sh <service> <sha>`. Make the new GHCR package **private**, like the
   others, so the server's stored login keeps working.
6. **Verify:** §4's lines for the tier, then its host in a browser.
7. For the writer: **the API build with decision 0056** (the writer limits) must
   be live before writers use the portal; deploy `qbank-api` first if it is not.

Roll back the tier alone with `./scripts/rollback.sh <service> <tag>`; nothing
else restarts.

## First deploy on a new server (the qfoundry.in hosts)

Phase 4 of the workspace roadmap `docs/roadmaps/qfoundry-brand-and-hostnames.md`.
The previous server was deleted on 2026-11-07, so this is a clean bootstrap, not
a migration: sections 0 to 4 above are the procedure, and this section only fixes
the order and the values that are new. Delete it once the server is live.

```bash
# 1. Provision the box: INSTRUCTION.md steps 1 to 3 (harden, SSH keys, Docker
#    permissions). Nothing here runs until `docker info` works for the deploy
#    account.

# 2. DNS at the registrar, low TTL, A records on the NEW server's IP:
#    qfoundry.in (@), www.qfoundry.in, studio.qfoundry.in, prep.qfoundry.in,
#    writer.qfoundry.in. The apex and www. share one certificate, so both must
#    resolve before the homepage's first deploy.
dig +short qfoundry.in www.qfoundry.in studio.qfoundry.in prep.qfoundry.in writer.qfoundry.in

# 3. Push qbank-deploy first: setup-app.sh fetches it from GitHub. Nothing
#    deploys from this push (this repo has no workflow).

# 4. On the server, as the account CI will connect as:
curl -fsSL https://raw.githubusercontent.com/mroshan74/qbank-deploy/main/scripts/setup-app.sh | bash
cd /opt/qbank && nano .env
#    HOMEPAGE_HOST=qfoundry.in   ADMIN_HOST=studio.qfoundry.in
#    LEARNER_HOST=prep.qfoundry.in   WRITER_HOST=writer.qfoundry.in
#    CLIENT_URL=https://studio.qfoundry.in,https://prep.qfoundry.in,https://writer.qfoundry.in
#    (all five are already these values in .env.example; do not retype them.
#    The domain is qfoundry.in, NOT .com: a wrong host burns Let's Encrypt's
#    five attempts an hour. ./scripts/check-hosts.sh proves .env and DNS.)
#    MONGODB_URI=... with the database name `qbank` (a fresh database on Atlas),
#    JWT_SECRET, OPENAI_API_KEY, OTP_PROVIDER=message_central and the two
#    MESSAGE_CENTRAL_* values, SEED_SUPERADMIN_*; every *_TAG stays `latest`.
#    Leave PORT=5000 alone: the api image listens there and nginx proxies to it.
./scripts/check-hosts.sh            # .env matches .env.example, and all five names resolve here
ACME_EMAIL=you@example.com docker compose -f compose.traefik.yml -p traefik up -d   # section 1
docker login ghcr.io                                                                 # if declined in setup-app.sh

# 5. GitHub: set the four deploy secrets on ALL FIVE app repos (qbank-api,
#    qbank-admin, qbank-learner, qbank-writer, qbank-homepage): VPS_HOST (the
#    new IP), VPS_USER (setup-app.sh printed it), VPS_SSH_KEY,
#    VPS_SSH_KEY_PASSPHRASE. The old values point at a server that no longer
#    exists, so every repo needs new ones, not only the two new repos.

# 6. Push the app repos in this order, letting each CI run finish:
#    qbank-api, qbank-homepage, qbank-learner, qbank-writer, qbank-admin.
#    Mind the branch each workflow watches: `master` for qbank-api and
#    qbank-admin, `main` for the other three.
#    Each run builds ghcr.io/mroshan74/<repo>:<sha> and :latest and runs
#    deploy.sh <service> <sha>; the first run of each creates its container and
#    Traefik requests its certificate (watch `docker logs traefik` for ACME).
#    The api's run is proved at the api container itself (there is no web
#    container yet; deploy.sh says so and carries on); every later run is
#    proved through its own tier's nginx, the way a browser reaches it.
#    The GHCR packages are private because the repos are; check once.

# 7. Seed the empty database: section 3.
docker compose -f compose.prod.yml -p qbank --profile seed run --rm seed

# 8. Verify: section 4, plus
curl -sI https://www.qfoundry.in/ | grep -i '^location'        # the apex
curl -s https://qfoundry.in/healthz                             # ok
#    studio/ lands on /login; a staff, a writer and a learner sign-in; a
#    community-organization PDF says "Prepared with QFoundry".
./scripts/rollback.sh homepage <sha>   # once, to prove the path; it is a no-op redeploy

# 9. Clean up what the old server left behind elsewhere: drop the `pscarchiver`
#    database in Atlas, delete the old psc-archiver-* GHCR packages, and remove
#    the trynbuild DNS records (the QA domain; no redirects).
```

---

## When it goes wrong

| Symptom | Cause |
|---|---|
| `network traefik_proxy declared as external, but could not be found` | Step 1 was skipped |
| `deploy.sh api` says `No running web container to probe through` | Informational. Nothing has deployed the admin yet, so the api is proved at its own port; the line disappears after the first `web` deploy |
| Seed stops at `API did not become ready` | The api container is not up, or is unhealthy. `docker compose -f compose.prod.yml -p qbank logs api` |
| Seed stops at `Login failed (401)` | `SEED_SUPERADMIN_USERNAME` / `SEED_SUPERADMIN_PASSWORD` in `.env` do not match the account already in the database |
| `Refusing to import: N questions ... are not in the seed files` | The database is not empty and predates `_id` matching. Clear it and re-run step 3 |
| `unauthorized` / `denied` pulling an image | No GHCR login on this account, or a fine-grained PAT instead of a classic one with `read:packages` |
| `manifest unknown` pulling `:latest` | That repo's workflow has never completed a build, so no `:latest` exists yet. Push once, or set that one tag back to a short SHA that does exist |
| A refresh pulled nothing and the app looks unchanged | `:latest` has not moved since the last pull. Confirm the build actually ran, then compare `docker compose -f compose.prod.yml -p qbank images` before and after |
| Certificate not issued | DNS does not resolve yet. `dig +short` the host (for the homepage **both** the apex and `www.`, they share one certificate), then `docker logs traefik` |

Longer list, with the reasoning: [README.md → Troubleshooting](README.md#troubleshooting).
