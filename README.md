# qbank-deploy

Deployment configuration for **QFoundry** — the NestJS API (`qbank-api`)
and its four React frontends: the staff back office (`qbank-admin`), the
learner-facing app (`qbank-learner`), the question writer portal
(`qbank-writer`) and the static marketing site at the apex (`qbank-homepage`).

Infrastructure lives in its own repo on purpose. In the two predecessor
projects it was buried inside an application repo, and in both cases the copy
on the server silently drifted from the copy in git. Here, `deploy.sh` pulls
this repo on every deploy, so the server can only run what is committed.

> **Standing a torn-down server back up?** You want
> **[QUICKSTART.md](QUICKSTART.md)** — the same path as below, as commands to
> paste in order, with nothing to read. This file is the reference behind it.

---

## Before your first deploy

Fill these in. The four hostnames and `CLIENT_URL` are already the real
production values in `.env.example` (the domain is `qfoundry.in`, **not**
`.com`), so a `.env` copied from it is right as long as nobody retypes them;
`scripts/check-hosts.sh` refuses to deploy if they drift. Everything else uses
placeholders.

| Placeholder | Where | What to put |
|---|---|---|
| `HOMEPAGE_HOST` | `/opt/qbank/.env` | The marketing site's hostname, the bare apex: `qfoundry.in`. Its router also answers `www.` and redirects it to the apex, so **both** DNS records must exist |
| `ADMIN_HOST` | `.env` | Staff back-office hostname: `studio.qfoundry.in` |
| `LEARNER_HOST` | `.env` | Learner-app hostname: `prep.qfoundry.in` |
| `WRITER_HOST` | `.env` | Writer-portal hostname: `writer.qfoundry.in` |
| `CLIENT_URL` | `.env` | The API's CORS allow-list. Must name **every** app origin (studio, prep, writer), comma-separated; the homepage makes no API call and is left out |
| `ACME_EMAIL` | passed to `compose.traefik.yml` | Where Let's Encrypt sends expiry warnings |
| `REPO_URL` | `scripts/setup-app.sh` | This repo's clone URL, if not `mroshan74/qbank-deploy` |
| `API_IMAGE` / `WEB_IMAGE` / `LEARNER_IMAGE` / `WRITER_IMAGE` / `HOMEPAGE_IMAGE` | `.env` | GHCR paths, if the owner is not `mroshan74` |
| `MONGODB_URI`, `JWT_SECRET`, `OPENAI_API_KEY` | `.env` | Real credentials |
| `MESSAGE_CENTRAL_CUSTOMER_ID`, `MESSAGE_CENTRAL_KEY` | `.env` | Learner sign-in by SMS. The **key is the account password base64-encoded**, not the password |
| `TELEGRAM_BOT_TOKEN` | `.env`, **optional** | The production Telegram bot's token, from BotFather. Absent or empty, Telegram is off and nothing else changes. See [Switch Telegram on](#switch-telegram-on) |

> ⚠ **Leaving `OTP_PROVIDER` out disables learner sign-in.** The API's code
> default is `console`, which sends no SMS at all, so the key is set to
> `message_central` in `.env.example` rather than left blank. `console` also
> returns the one-time code in the response body on any `NODE_ENV` other than
> `production` — so on a server, that one variable is what stands between a
> misconfiguration and handing out sessions. The two Message Central
> credentials are validated in the sender's constructor: a missing one fails
> the API's **boot**, which takes staff login down too. That is intended — a
> misconfigured provider should not first surface as one learner's failed
> sign-in.

> ⚠ **Every frontend tier adds three keys** (`X_HOST`, `X_TAG`, `X_IMAGE`: the
> `WRITER_*` set for the writer portal, the `HOMEPAGE_*` set for the marketing
> site). `deploy.sh` compares the server's `.env` with `.env.example` and pulls
> this repo first, so once a version naming new keys is on the server **every**
> deploy (api, web, learner too) stops on the env check until they are in
> `/opt/qbank/.env`. Add them, and the DNS record for the new host, **before** the
> first push that carries them. Order: [QUICKSTART.md → Adding a frontend tier](QUICKSTART.md#adding-a-frontend-tier-to-a-running-server).

> ⚠ **`APP_HOST` was renamed to `ADMIN_HOST`** when the learner app arrived. A
> server whose `.env` still has the old key stops on `deploy.sh`'s environment
> check — which runs **before anything is touched**, so a mistimed deploy is a
> clean no-op rather than an outage. Rename the key by hand and re-run.

---

## Architecture

```
                        ┌──────────── VPS ────────────────────────────────┐
  browser ─── HTTPS ──▶ │  traefik  (:80 → :443, Let's Encrypt)           │
                        │     │                                           │
                        │     ├─▶ Host(HOMEPAGE_HOST) | www. ──▶ apex    │
                        │     │    homepage nginx ── marketing site       │
                        │     │              (static, no /api)            │
                        │     │                                           │
                        │     ├─▶ Host(ADMIN_HOST)                        │
                        │     │    web      nginx ── admin SPA            │
                        │     │              ├───── /api/* ──proxy─┐      │
                        │     │              └───── /fonts/* (PDF faces)  │
                        │     │                                    │      │
                        │     ├─▶ Host(LEARNER_HOST)               ├─▶ api│
                        │     │    learner  nginx ── learner SPA   │ :5000│
                        │     │              ├───── /api/* ──proxy─┤      │
                        │     │              └───── /fonts/* (PDF faces)  │
                        │     │                                    │      │
                        │     └─▶ Host(WRITER_HOST)                │      │
                        │          writer   nginx ── writer SPA    │      │
                        │                    ├──── /api/* ──proxy──┘      │
                        │                    └──── /fonts/* (Malayalam)   │
                        └─────────────────────────────────────────────────┘
                                                             │
                                                             ▼
                                                     MongoDB Atlas
```

**One hostname per SPA, each its own origin.** Each SPA is built with an empty
`VITE_BACKEND_URL`, so it calls the relative path `/api`, and its own nginx
forwards that to the shared API container. Two SPAs cannot both own `/` behind
one origin, which is why this is a second hostname rather than a path prefix.
Consequences worth knowing:

- No CORS in production — but **four** TLS certificates (the homepage's carries
  both the apex and `www.`), so every DNS record, `www.` included, must resolve
  here before its first deploy.
- The API is **never routed by Traefik** (`traefik.enable=false`) and publishes
  no host port. It is only reachable from inside the Docker network.
- Traefik router and service names must be unique across the whole Docker
  provider: the admin's are `archiver`, the learner's `learner`, the writer's
  `writer`, the homepage's `homepage` (plus its `homepage-www-to-apex`
  redirect middleware).
- Every web image works locally and in production — there is no baked-in backend
  hostname, so no per-environment rebuild.
- `CLIENT_URL` (the API's CORS allow-list) **replaces** the built-in fallback
  rather than extending it, so it has to name every origin. Adding a third
  frontend without updating it silently drops the others.

## Repository layout

| File | Purpose |
|---|---|
| `QUICKSTART.md` | Bring a torn-down server back up. Commands only, in paste order |
| `INSTRUCTION.md` | How the box itself was provisioned, before this repo ever reached it |
| `compose.prod.yml` | The production stack (`api` + `web` + `learner` + `writer` + `homepage`, plus the `seed` profile) |
| `compose.traefik.yml` | Edge proxy and TLS. Brought up once, then left alone |
| `compose.local.yml` | Prod-parity local stack, with its own MongoDB: `api`, `web`, `learner`, `writer`, `homepage` |
| `.env.example` | The key schema `deploy.sh` validates the server's `.env` against, and the record of the production hostnames |
| `scripts/check-hosts.sh` | Refuses a deploy whose hostnames differ from `.env.example`, whose `CLIENT_URL` misses an app origin, or whose names (plus `www.`) do not resolve to this server. Run by both deploy scripts before anything changes; safe to run by hand |
| `scripts/setup-app.sh` | One-time application setup on an already-provisioned server. Checks its prerequisites; provisions nothing |
| `scripts/deploy.sh` | What CI runs over SSH. One service, one pinned tag |
| `scripts/deploy-latest.sh` | Stop, pull `:latest`, start every service, verify. The manual test-round loop until the pipelines are wired up |
| `scripts/rollback.sh` | Redeploy an older tag |
| `scripts/bootstrap.mjs` | First-run bootstrap, for **both** stacks (the `seed` compose profile in each). Seeds the System organization, the superadmin, the taxonomy, then the bundled papers and questions. Runs *inside* the `api` container — the host never needs Node.js, only Docker |
| `docs/roadmaps/` | Planned work, one phase at a time. [server-bootstrap-runbook.md](docs/roadmaps/server-bootstrap-runbook.md) is complete; the current server work is Phase 4 of the workspace roadmap [qfoundry-brand-and-hostnames.md](../docs/roadmaps/qfoundry-brand-and-hostnames.md), the first deploy on the new server |

---

## Run it locally

The local stack runs the **same images, same nginx, same routing** as
production. It is the fastest way to see the app, demo it, or check a change
before pushing — and it is where the deployment setup itself gets tested.

```bash
# clone next to qbank-api, qbank-admin, qbank-learner, qbank-writer and
# qbank-homepage — the compose build contexts are ../<repo>, so all six sit
# side by side
git clone <this repo>
cd qbank-deploy

docker compose -f compose.local.yml up -d --build          # builds your working tree
docker compose -f compose.local.yml --profile seed run --rm seed   # first run only
```

| | URL | |
|---|---|---|
| **Admin** | http://localhost:8080 | sign in as `superadmin` / `ChangeMe123!` (you will be asked to set a new password) |
| **Learner** | http://localhost:8081 | sign in by mobile number; the one-time code is printed in the api logs |
| **Writer** | http://localhost:8082 | sign in with a `writer` account created in the admin (username and password); assign it a draft exam paper there first |
| **Homepage** | http://localhost:8083 | the marketing site; nothing to sign in to. Its Sign in links point at the production hosts |

Override the seeded account with `SEED_SUPERADMIN_USERNAME` /
`SEED_SUPERADMIN_PASSWORD`, and the ports with `WEB_PORT` / `LEARNER_PORT` /
`WRITER_PORT` / `HOMEPAGE_PORT`. The `writer` and `homepage` services build
`../qbank-writer` and `../qbank-homepage`; both reach the server in Phase 4 of
the workspace roadmap `docs/roadmaps/qfoundry-brand-and-hostnames.md`.

**Telegram is off here by default.** The api container gets `TELEGRAM_BOT_TOKEN`
empty, which leaves the API's Telegram module inert (`/api/telegram/*` answers
503; `qbank-api/doc/decisions/0063-telegram-integration.md`). To try it, put the
**dev** bot's token in a `.env` beside `compose.local.yml` and recreate the api
container. Never the production bot's: updates arrive by long polling, and two
processes polling one bot knock each other out. `TELEGRAM_API_BASE_URL` points
the API at a stand-in Bot API server for checks that need no real bot, and
`LEARNER_APP_URL` (default `http://localhost:8081`) is the address the bot puts
behind a post's button; Telegram refuses a `localhost` address there, so a post
made from this stack needs a real https host to carry one. The server keys land
in Phase 6 of `qbank-api/doc/roadmaps/telegram-integration.md`.

> **This stack is the only place three things get tested before a server sees
> them**, because `pnpm dev` exercises none of them: each SPA's single-origin
> `/api` proxy (dev is cross-origin to `:5000`); **both** apps' PDF fonts, which
> are fetched over HTTP at render time from `/fonts/` — including
> `Century Schoolbook Std Regular.otf`, spaces and all — where a 404 fails every
> Malayalam export with no CDN fallback; and **whether the images build at all**,
> since the Dockerfile deliberately sees a narrower file set than a developer
> machine does. Run it with `--build` after touching either app's `nginx.conf`,
> `Dockerfile`, or dependency manifests, then download a paper and watch the
> network tab for the six font requests.

The seed step is idempotent — re-running it creates nothing twice (classifications
are the exception, see the taxonomy note below). Papers and
questions are matched against the `_id` in the seed files, so a repeat run
**updates** the rows that are already there instead of skipping or duplicating
them. That makes re-running the `seed` profile the way to pick up a correction
to the seed data, not just a first-run step.

The script always runs a **check** before it writes, then reports true change
counts — `created` is genuinely new rows and `changed` is rows whose content
actually differed, because the seeder does not stamp `updatedAt`. A re-run with
no edits to the seed files therefore reports **zero of both**:

```
# first run
[seed] Check: papers to create 163, already present 0, questions to add 14868, to refresh 0, not in the files 0.
[seed] Done. Papers created: 163, already present: 0, questions created: 14868, changed: 0, brought back: 0.

# every run after, with no seed-file edits
[seed] Check: papers to create 0, already present 163, questions to add 0, to refresh 14868, not in the files 0.
[seed] Done. Papers created: 0, already present: 163, questions created: 0, changed: 0, brought back: 0.
```

> ⚠ **A database seeded before the `_id`-matching seeder must be wiped first.**
> The earlier seeder discarded the source `_id`s, so those questions cannot be
> matched and an import would insert a *second* full copy (14,868 → 29,833).
> **The check now catches this and the script refuses to write** — it reports the
> unmatched rows under `not in the files`. There is no migration and none is
> planned: the app is pre-deployment, so the reset is simply to drop the two
> seeder-owned collections and seed again:
>
> ```bash
> docker compose -f compose.local.yml exec mongo mongosh qbank \
>   --eval 'db.questions.drop(); db.exampapers.drop()'
> docker compose -f compose.local.yml --profile seed run --rm seed
> ```
>
> This leaves `users`, `appsettings` and `paperseries` alone, so you stay signed
> in with the same account. Set `SEED_FORCE=1` to import anyway — only do that
> when you know the extra questions are ones you added deliberately and want to
> keep.

Two more things a re-run does, both reported rather than silent: it **brings
back** papers and questions that were deleted but are still listed in the seed
files (the files are the source of truth), and it **resets a paper's status** to
whatever the file says. The seeder never deletes anything — questions on a
seeded paper that the files no longer list are counted under `not in the files`
and left alone.

It runs `scripts/bootstrap.mjs` *inside* the `api` image's own Node (via the
`seed` profile above) — the host you run these commands on never needs Node.js
installed, only Docker. The **same script and the same profile exist in
`compose.prod.yml`**, so a server is seeded by the command this section
rehearses, not by a different one.

**Taxonomy is the one part that is not idempotent by itself, so the script
guards it.** `POST /api/taxonomy/seed` mints a *new* version on every call and
activates it, which on a re-run would leave you with v1, v2, v3… The script
therefore reads `GET /api/taxonomy/versions` first and seeds only into an empty
list, reporting `Taxonomy already seeded: N version(s), active vN. Skipped.`
otherwise. `SEED_TAXONOMY_FORCE=1` adds one deliberately — which is what you
want after editing `src/taxonomy/data/taxonomy-seed.json` in the API, since a
taxonomy change ships as a new version rather than an edit to the old one.

> ⚠ **The question seed is classified, and the classifications are locked to
> one taxonomy revision** (API commit `36b2fd3`, 21 October 2026). Every
> question in `pscdatabuilder.questions.json` now carries an AI classification
> made against the bundled taxonomy `2026-10-21-review-4`, pinned by
> `pscdatabuilder.classification-manifest.json`. Three things follow:
>
> - **A fresh database seeds cleanly.** Drop the *whole* database (taxonomy
>   included) and the script seeds review-4 first, then the content passes. No
>   OpenAI spend is involved; the classifications come from the committed file.
> - **An existing database with an older taxonomy refuses the content step**
>   with `Seed classifications were rejected before any writes: Activate the
>   matching bundled taxonomy before importing classified questions`. Nothing is
>   written. Dropping only `questions` and `exampapers` (the reset above) does
>   not help, because the old taxonomy survives. Re-run once with
>   `SEED_TAXONOMY_FORCE=1` to add and activate the bundled revision.
> - **A re-run overwrites classification reviews.** Papers and question content
>   stay idempotent, but every question's classification is replaced with the
>   seed's, including decisions a reviewer made in the admin app. Once reviews
>   have started on a database, do not re-run the seed against it.
>
> The lock covers the question seed, `exam-papers.bulk.v2.json` and
> `taxonomy-seed.json` (manifest version 2, API decision 0051). An edit to any
> of them makes every import refuse with `The seed files changed after the
> classification manifest was written (...)` until the manifest is re-hashed.
> **Re-hash in a local API checkout, never on a server** (writes are off there),
> with `POST /api/seeder/manifest/rehash`, and commit the manifest with the
> edit. That is free for fields the classifier never saw; an edit it did see
> must be accepted explicitly or re-classified, which costs about USD 50. A
> taxonomy edit that changes labels, scope, tags, rules or the revision still
> needs `SEED_TAXONOMY_FORCE=1` on an existing database, as the paragraph above
> describes. Details, the exit plan and the image-size options:
> [qbank-api/doc/taxonomy/local-seed-classification.md](../qbank-api/doc/taxonomy/local-seed-classification.md).

To run an exact published build instead of your working tree:

```bash
export API_IMAGE=ghcr.io/mroshan74/qbank-api
export WEB_IMAGE=ghcr.io/mroshan74/qbank-admin
export LEARNER_IMAGE=ghcr.io/mroshan74/qbank-learner
export WRITER_IMAGE=ghcr.io/mroshan74/qbank-writer
export HOMEPAGE_IMAGE=ghcr.io/mroshan74/qbank-homepage
export API_TAG=a1b2c3d WEB_TAG=a1b2c3d LEARNER_TAG=a1b2c3d WRITER_TAG=a1b2c3d HOMEPAGE_TAG=a1b2c3d
docker compose -f compose.local.yml pull
docker compose -f compose.local.yml up -d --no-build
```

Other useful bits:

```bash
docker compose -f compose.local.yml logs -f api      # follow API logs
docker compose -f compose.local.yml down             # stop, keep data
docker compose -f compose.local.yml down -v          # stop and wipe the database
```

MongoDB is published on **27018** (not 27017) so it never collides with a
MongoDB you already run. It is a throwaway container: this stack never touches
Atlas, so a demo cannot damage real data.

---

## Prerequisites — provisioned by whoever owns the server

Server provisioning belongs to the platform team, not to an application
deploy. **Nothing in this repo installs packages, creates users or groups,
writes SSH keys, edits `sshd_config`, or configures the firewall.** The setup
script checks for what it needs and stops with a specific ask when something
is missing.

The following must already be true before the application can be set up:

| Requirement | Notes |
|---|---|
| Docker Engine + the Compose plugin | `setup-app.sh` verifies, never installs |
| An account to SSH in as, able to reach the Docker socket (typically via the `docker` group), that the developer doing setup can log in to | never created here. A dedicated service account is preferred; `root` works |
| The CI public key installed on that account's `authorized_keys` | needed before the first CI *deploy*, not before setup. Never written here — you generate the keypair (below) and hand over the public half |
| `/opt/qbank`, owned by that account | the one thing `setup-app.sh` offers to do itself — it prints the `sudo install -d` and waits for a `y` before running it. Answer `n` and it stops, unchanged |
| Inbound 80 and 443 reachable, and SSH reachable from GitHub Actions | never changed here |

---

## Set up the application

A one-time manual step, run by a developer after the server is handed over and
**before the first CI deploy**. CI never runs it — CI only runs `deploy.sh`,
which is on the server because this put it there.

```bash
ssh <account>@<vps>
curl -fsSL https://raw.githubusercontent.com/mroshan74/qbank-deploy/main/scripts/setup-app.sh | bash
```

**Whichever account you SSH in as is the account CI must use.** The script
checks *that* account — not a hardcoded one — for Docker access and write
access to `/opt/qbank`, and prints it at the end as the value for the
`VPS_USER` secret. Setting up as one account while CI connects as another is
the classic failure: `deploy.sh`'s `git pull` and its `sed -i` on `.env` both
need to write there, and fail with "permission denied" otherwise.

It then clones this repo to `/opt/qbank` and creates `.env` from the
template. It prints the remaining manual steps when it finishes, and also
saves them to `/opt/qbank/REMAINING-STEPS.txt` in case your session
drops before you're done — `cat` that file anytime, or just re-run the script;
it's idempotent and safe to repeat.

**It stops and asks twice**, and in both cases prints the exact command before
running anything:

| Prompt | If you answer `y` | If you answer `n` |
|---|---|---|
| Create (or hand over) `/opt/qbank` — the one privileged command | runs that single `sudo` and continues | stops immediately, server unchanged, and prints the command to pass to whoever administers it |
| Log in to ghcr.io | asks for your GitHub username and PAT (input hidden, piped straight to `--password-stdin` — never echoed, never a shell argument, never written anywhere but Docker's own config) | carries on; it stays in the printed steps for later |

It skips the second prompt entirely if credentials for `ghcr.io` are already
stored, and the printed steps reflect what is actually still outstanding — a
login you completed does not sit there looking pending. Prompts read from
`/dev/tty`, so they work under `curl … | bash`; with no terminal at all
(a non-interactive run) both answer "no".

**A key dedicated to CI.** Generate one (don't reuse a personal key):

```bash
ssh-keygen -t ed25519 -C qbank-ci -f ci-deploy-key
```

Hand `ci-deploy-key.pub` to whoever manages access on that server, to be
installed on the account above. Then, in the GitHub settings of **all five**
app repos — `qbank-api`, `qbank-admin`, `qbank-learner`, `qbank-writer`,
`qbank-homepage` — add these secrets:

| Secret | Value |
|---|---|
| `VPS_HOST` | Server IP or hostname |
| `VPS_USER` | The account `setup-app.sh` ran as — it prints the exact value |
| `VPS_SSH_KEY` | Contents of `ci-deploy-key` (the private half) |
| `VPS_SSH_KEY_PASSPHRASE` | The passphrase you set above |

That covers the **push**: CI authenticates to GHCR with the built-in
`GITHUB_TOKEN`, no secret to add. It does not cover the **pull** — all five
GHCR packages are private (they inherit that from the source repos), and the VPS
has no access to `GITHUB_TOKEN`, so it needs its own one-time login before
the first deploy. `setup-app.sh` offers to do this for you; to do it by hand
instead, or later:

```bash
ssh <VPS_USER>@<vps>
# Generate at github.com/settings/tokens — classic PAT, scope: read:packages
echo "<PAT>" | docker login ghcr.io -u <your-github-username> --password-stdin
```

One-time only: Docker persists this to that account's `~/.docker/config.json`,
so every later `docker compose pull` — CI-triggered or by hand —
authenticates automatically from here on. Skip this entirely by
making the five GHCR packages public instead (repo → Packages → package →
Package settings → visibility) if you'd rather not manage this credential.

**Bring Traefik up before the app stack.** The `compose.traefik.yml` stack
owns the shared `traefik_proxy` network; `compose.prod.yml` joins it as
`external`, so starting the app stack first on a fresh server fails with
`network traefik_proxy declared as external, but could not be found`.

---

## Deploy

**Normally you do nothing.** Push to the default branch in any of the five app
repos and CI builds, publishes to GHCR, and runs `deploy.sh` over SSH. Note the
branch differs: `master` for the api and admin, **`main`** for the learner app,
the writer portal and the homepage. (This
infrastructure repo is on `main` too, which is what `deploy.sh`'s `git pull` and
the `setup-app.sh` bootstrap URL both track.)

| Repo | Service | Image |
|---|---|---|
| `qbank-api` | `api` | `ghcr.io/mroshan74/qbank-api` |
| `qbank-admin` | `web` | `ghcr.io/mroshan74/qbank-admin` |
| `qbank-learner` | `learner` | `ghcr.io/mroshan74/qbank-learner` |
| `qbank-writer` | `writer` | `ghcr.io/mroshan74/qbank-writer` |
| `qbank-homepage` | `homepage` | `ghcr.io/mroshan74/qbank-homepage` |

By hand, on the server:

```bash
cd /opt/qbank
./scripts/deploy.sh api a1b2c3d
./scripts/deploy.sh web a1b2c3d       # staff back office
./scripts/deploy.sh learner a1b2c3d   # learner-facing app
./scripts/deploy.sh writer a1b2c3d    # question writer portal
./scripts/deploy.sh homepage a1b2c3d  # marketing site
```

**The very first deploy on a brand-new server works through CI too, in the
right order.** Step 5 below normally polls `/api/readyz` *through the nginx of
the tier just deployed*, and an `api` deploy is proved through `web`. On a
server where nothing has ever run there is no `web` container yet, so
`deploy.sh api` notices, says `No running web container to probe through`, and
proves the api at its own port (`127.0.0.1:5000/api/readyz` inside the api
container) instead. Every frontend deployed after that is proved through its
own nginx against an api that is already serving. So the push order on a fresh
box is **api first**, then the frontends (the homepage needs no api at all);
the paste-ready version is [QUICKSTART.md → First deploy on a new
server](QUICKSTART.md#first-deploy-on-a-new-server-the-qfoundryin-hosts).

To start everything at once by hand instead, after every `*_TAG` in `.env`
(`API_TAG`, `WEB_TAG`, `LEARNER_TAG`, `WRITER_TAG`, `HOMEPAGE_TAG`) names a
published tag:

```bash
docker compose -f compose.prod.yml -p qbank up -d
```

Adding a new frontend to a stack that is already running needs no special
handling either: `deploy.sh` creates the container in step 4 and probes it in
step 5, and the api it proxies to is already serving.

`deploy.sh` will:

1. `git pull` this repo, so the config is the committed one
2. check the server's `.env` has every key present in `.env.example`, and
   **abort before touching anything** if not
3. write the tag into `.env` (`API_TAG` / `WEB_TAG` / `LEARNER_TAG` /
   `WRITER_TAG` / `HOMEPAGE_TAG`, and `BUILD_ID` for the api)
4. pull the image, then recreate only that one service
5. poll `/api/readyz` **from inside the nginx container of the tier just
   deployed** — the real browser path. `learner` and `writer` deploys are
   verified through their own nginx; `api` and `web` deploys go through `web`
   (or, when no `web` container exists yet, the api is probed at its own port);
   the `homepage` has no `/api` and is probed at its own `/healthz`
6. prune images older than 7 days, keeping a week of rollback targets

Step 5 normally costs 3–10 seconds: the loop probes once *before* its first
sleep, so a container that is already serving passes immediately. The 60s in
the script is the failure deadline, not the usual cost. It is not redundant
with the container healthchecks below — plain Compose only *reports* health, it
never restarts an unhealthy-but-running container, and `restart: unless-stopped`
fires on process exit rather than on unhealthy.

**Only one deploy runs at a time.** `deploy.sh` takes an exclusive `flock` on
`.deploy.lock` in this directory and waits up to 5 minutes for a running deploy
to finish. The lock is shared across accounts (the file is created `0666`), so a
hand-run rollback as `root` and a CI deploy as `VPS_USER` still exclude each
other. This is not covered by GitHub's `concurrency:` group, which is per-repo
and so cannot serialise the five app repos' deploys against each other.

Expect a few seconds of downtime while the container restarts. That is
accepted: this pipeline optimises for fast, verified iteration rather than
availability. Real zero-downtime needs two API replicas, which needs a
distributed lock first (see *Known constraints*).

### Refresh to the latest images by hand (no pipeline yet)

Until the git pipelines are driving deploys, the fastest loop is to point the
stack at `latest` and pull. All five workflows already publish `:latest`
alongside the immutable `:<short-sha>` tag, so this picks up whatever was last
built without anyone having to look a SHA up.

```bash
cd /opt/qbank
./scripts/deploy-latest.sh          # stop, pull, start, verify
./scripts/deploy-latest.sh --seed   # ...and seed a freshly cleared database
```

| Flag | Does |
|---|---|
| *(none)* | `down`, `pull`, `up -d`, then probe every nginx tier (`/api/readyz` through the three app tiers, `/healthz` on the homepage) |
| `--seed` | also runs the `seed` profile once the api answers |
| `--no-down` | skip the stop, so compose recreates only services whose image ID changed and an unchanged frontend is not bounced |
| `--tag <tag>` | point all five services at a pinned tag instead of `latest` |

It shares `deploy.sh`'s guarantees deliberately: the same `.env`-against-
`.env.example` key check **before anything is touched**, the same `.deploy.lock`
so a hand-run refresh and a CI deploy cannot interleave their `sed -i` on `.env`,
and the same `git pull --ff-only` so the server runs committed config. What it
does *not* share is the rollback trail — see the second warning below.

Where it differs from `deploy.sh`, and why both exist:

| | `deploy.sh` | `deploy-latest.sh` |
|---|---|---|
| Scope | one service | all five |
| Tag | pinned short SHA | floating `latest` (or `--tag`) |
| Restart | `up -d --no-deps <svc>` | full `down` then `up -d` |
| Rollback trail | yes, `.env` records the tag | no, while the tag floats |
| Runs from | CI, and by hand | by hand only |

Doing it without the script, which is all the script does:

```bash
cd /opt/qbank

# once: point every service at the newest published image
sed -i 's/^API_TAG=.*/API_TAG=latest/;s/^WEB_TAG=.*/WEB_TAG=latest/;s/^LEARNER_TAG=.*/LEARNER_TAG=latest/;s/^WRITER_TAG=.*/WRITER_TAG=latest/;s/^HOMEPAGE_TAG=.*/HOMEPAGE_TAG=latest/' .env

# each refresh: stamp a fresh BUILD_ID, stop, pull, start
sed -i "s/^BUILD_ID=.*/BUILD_ID=$(date +%y%m%d%H%M)-latest/" .env
docker compose -f compose.prod.yml -p qbank down
docker compose -f compose.prod.yml -p qbank pull
docker compose -f compose.prod.yml -p qbank up -d
```

**Re-stamping `BUILD_ID` is not cosmetic.** It is what retires sessions minted by
the previous build ([0004](../qbank-api/doc/decisions/0004-stateless-jwt-with-profile.md)),
which `deploy.sh` gets for free by writing the image tag into it. A `latest` tag
never changes, so without this line a tester keeps a token issued against the old
build and the version reported by `GET /api/readyz` and in the admin sidebar goes
stale.

> ⚠ **Never add `-v` to that `down`.** It deletes the `ai_tagging_jobs` volume,
> and OpenAI batch jobs run for minutes to 24 hours with their artefacts on it.
> It is also **not** a way to reset the database: that is MongoDB Atlas, which no
> compose command here touches.

> ⚠ **`latest` trades away rollback.** `rollback.sh` works by redeploying a
> pinned tag, and while `.env` says `latest` there is no record of which build is
> live — `docker compose -f compose.prod.yml -p qbank images` gives you the
> image IDs and nothing more. This is a deliberate convenience for MVP test runs.
> When the pipelines land, go back to pinned short-SHA tags, which is exactly what
> `deploy.sh` writes and why `compose.prod.yml` says never `:latest`.

Paste-ready version, with the seed step: [QUICKSTART.md](QUICKSTART.md#5-pull-the-latest-build-and-restart-everything).

### Container health

All five services carry a Docker healthcheck, so `docker compose -f
compose.prod.yml -p qbank ps` reports real status rather than just "Up":

| Service | Probe | Means |
|---------|-------|-------|
| `api` | `GET /api/readyz` on `127.0.0.1:5000` | process is up **and** MongoDB is connected |
| `web` | `GET /healthz` on `127.0.0.1:80` | admin nginx is serving (deliberately does not depend on the api) |
| `learner` | `GET /healthz` on `127.0.0.1:80` | learner nginx is serving (same — independent of the api) |
| `writer` | `GET /healthz` on `127.0.0.1:80` | writer nginx is serving (same — independent of the api) |
| `homepage` | `GET /healthz` on `127.0.0.1:80` | the marketing site's nginx is serving (it has no api to depend on) |

The api gets a 30s `start_period` for Nest boot plus the first Mongo
connection; failures inside that window don't count against it.

## Roll back

Every build is published under its own immutable short-SHA tag, and
`compose.prod.yml` resolves whatever tag `.env` names. So rollback is just a
deploy of an older tag:

```bash
cd /opt/qbank
./scripts/rollback.sh api                   # list tags available on this host
./scripts/rollback.sh api 9f8e7d6           # go back to that build
./scripts/rollback.sh learner 9f8e7d6       # same, for the learner app
./scripts/rollback.sh writer 9f8e7d6        # same, for the writer portal
./scripts/rollback.sh homepage 9f8e7d6      # same, for the marketing site
```

Or from the GitHub UI, without SSH: **Actions → Build, Push & Deploy → Run
workflow**, and put the old tag in the `tag` input. That path skips the build
entirely and only redeploys.

`deploy.sh` prints the tag it replaced at the end of every run, so the value to
roll back to is always in the previous deploy's log.

### Rolling back learner sign-in

`OTP_PROVIDER` looks like a switch you can flip back, and only one of its values
is actually a rollback:

| Value | As a rollback |
|---|---|
| revert the api image tag | ✅ The real one. Sign-in goes back to whatever the older build ran |
| `msg91` | ✅ Only once DLT template registration lands, and only after adding `MSG91_AUTH_KEY` / `MSG91_TEMPLATE_ID` to both `.env` and `.env.example` |
| `console` | ❌ **Not a rollback.** No SMS is sent, and the code is withheld from the response because `NODE_ENV=production`. That is not a degraded sign-in, it is no sign-in |

## Rotate a secret

```bash
ssh <VPS_USER>@<vps>
cd /opt/qbank
nano .env                                  # edit the value
./scripts/deploy.sh api "$(sed -n 's/^API_TAG=//p' .env)"   # redeploy the same tag
```

Rotating `JWT_SECRET` signs everyone out, which is the intended effect.

## Switch Telegram on

Telegram is a module of the API (`qbank-api/doc/decisions/0063-telegram-integration.md`):
one shared bot that an organization adds to its channel, and through which it
posts papers. It ships **off**. Nothing below is needed for a deploy to work.

1. **Create the production bot** in Telegram's BotFather (`/newbot`). Keep its
   token. This is a different bot from the one used on a developer machine or
   on the local stack: updates arrive by long polling, and two processes
   polling the same bot answer each other with `409 Conflict`.
2. **Add the token to the server's `.env`** and restart the API:

   ```bash
   cd /opt/qbank
   echo 'TELEGRAM_BOT_TOKEN=<the token>' >> .env
   docker compose -f compose.prod.yml -p qbank up -d api
   docker logs qbank-api 2>&1 | grep -i telegram | tail -3
   ```

   The log should say `Telegram updates: long polling started.` and
   `Telegram post queue started`. `LEARNER_APP_URL`, the address behind the
   button under a post, needs no line of its own: `compose.prod.yml` sets it to
   `https://<LEARNER_HOST>`.
3. **Grant the permission.** Nobody can use Telegram yet: `telegram:manage` is
   in no role's defaults. A superadmin grants it, in the admin's User
   Management, to the owner of each organization that should have it (the
   vendor's own included). The owner then sees Workspace settings, Telegram,
   connects a channel there, and posts from a paper's menu.

**To switch it off again**, remove the line (or empty it) and restart the API.
Connected channels and their history stay in the database; nothing is posted
and the admin says Telegram is not set up.

**If the token leaks**, revoke it in BotFather (`/revoke`), put the new one in
`.env` and restart the API. Whoever holds the token can post to every connected
channel, so treat it like `JWT_SECRET`.

Things that are true because of how it works:

- **One API container.** The bot's updates and the quiz queue both assume it,
  like the rate limits and the AI-tagging queue already do.
- **The same token signs learners in from inside Telegram.** With
  `TELEGRAM_BOT_TOKEN` set, the learner app opened as a Telegram Mini App signs
  a learner in from Telegram's launch data, with no code by SMS
  (`qbank-api/doc/decisions/0064-telegram-mini-app-sign-in.md`). There is no
  separate key or switch. A first sign-in needs the API's update loop, since
  the learner's number arrives as a message to the bot.
- **The API trusts `X-Forwarded-For` from private addresses**, so its rate
  limits count the visitor and not the frontend's nginx. That is safe because
  Traefik discards whatever a visitor puts in that header and writes its own.
  **If another public proxy is ever put in front of Traefik (a CDN), revisit
  it** (`app.set('trust proxy', ...)` in `qbank-api/src/main.ts`): the visitor
  would then be that proxy, and everyone would share one limit again.
- **No inbound route.** Telegram never calls this server; the API calls
  Telegram. Nothing changes in Traefik or nginx.
- **A quiz is paced on purpose**, one question every 3 seconds into a channel,
  which is Telegram's own limit. A restart in the middle is safe: the run
  resumes, and a question caught mid-send is counted as failed rather than
  posted twice.
- **The PDF posted to a channel is built in the admin's browser** and passes
  through the API in memory. nginx's 2 MB request cap on the admin host is the
  ceiling; the API refuses a file over 1.9 MB with a sentence.

### Sign in with Telegram

A separate switch from the bot, for the learner app's **Continue with
Telegram** button (`qbank-api/doc/04-auth.md`). It lets a learner sign in
without an SMS code: Telegram vouches for their number if they agree to share
it. It is off until both values below are set, and it changes nothing about
one-time codes, which stay with Message Central.

1. In BotFather, open the production bot, then **Login Widget**. Add
   `https://<LEARNER_HOST>/login/telegram` to the allowed addresses (and the
   bare `https://<LEARNER_HOST>` origin). Note the **Client ID** and **Client
   Secret** shown there.
2. Add them to the server's `.env` and restart the API:

   ```bash
   cd /opt/qbank
   printf 'TELEGRAM_LOGIN_CLIENT_ID=<the id>\nTELEGRAM_LOGIN_CLIENT_SECRET=<the secret>\n' >> .env
   docker compose -f compose.prod.yml -p qbank up -d api
   curl -s https://<LEARNER_HOST>/api/auth/telegram/config
   # → {"enabled":true,"clientId":"...","authorizeUrl":"https://oauth.telegram.org/auth",...}
   ```

3. Open the learner app signed out. The sign-in screen now has the button.

`CLIENT_URL` must already name the learner origin (it does in the template).
To switch it off, remove the two lines and restart the API; the button goes and
nobody is signed out. **This has not yet been run against Telegram's own login
server**, only against a stand-in: do the first sign-in yourself before
telling anyone about it.

## Bootstrap a fresh database

The app has never been in production, so there is no migration path — a fresh
database is seeded from scratch. **One command does all of it**, and it is the
same script and the same profile the local stack uses:

```bash
cd /opt/qbank
docker compose -f compose.prod.yml -p qbank --profile seed run --rm seed
```

Four steps, in this order, because each depends on the one before:

| # | Step | How |
|---|---|---|
| 1 | The **System organization** at fixed `_id` `6a71ad994b228f7bf76fb570`, then the **superadmin** at fixed `_id` `6a71ad994b228f7bf76fb569` | `dist/scripts/seed-superadmin.js`, straight to MongoDB. The API does not need to be up |
| 2 | Wait for `GET /api/readyz` | polled over the internal network |
| 3 | **Taxonomy**, if the database has none | `POST /api/taxonomy/seed` |
| 4 | **163 exam papers and 14,868 questions** | `POST /api/seeder/import`, check first, then write |

**Steps 3 and 4 go over the compose network to `api:5000`, so nobody signs in or
calls the API by hand.** That is the whole point of the profile: the previous
procedure was to obtain a token and POST the seeder yourself, and it was easy to
do against the wrong host.

**The organization comes first and that ordering is load-bearing.** Since the
multi-tenant work, every staff role requires an organization, so a superadmin
created before one exists fails schema validation. The script writes both, and
the ids are fixed so re-seeding, export and import never change or unlink them.
If a superadmin already exists under a *different* `_id`, it warns and exits
rather than creating a second account — check the output, not just the exit code.

Everything is **safe to re-run**, and re-running is how you pick up a correction
to the seed data rather than a first-run-only step. On a second run every line
reports a skip or a zero.

**What is not idempotent, and how it is handled:**

- **Taxonomy.** `POST /api/taxonomy/seed` mints a new version on every call and
  activates it. The script reads `GET /api/taxonomy/versions` first and seeds
  only into an empty list. `SEED_TAXONOMY_FORCE=1` adds one deliberately, which
  is what you want after the API's bundled `taxonomy-seed.json` changes.
- **Content, on a database that predates `_id` matching.** `dryRun` runs first
  and the script refuses the write when `questionsUnmatchedCount` is non-zero,
  because importing would insert a second copy of every question. `SEED_FORCE=1`
  overrides, and on a production database a non-zero count is a reason to stop
  and look rather than to force.

The content run is also validated up front: a bad or duplicated `_id` in the seed
files, or a paper code belonging to a different paper than the file's `_id` does,
rejects the whole request with the list of problems and **nothing is written**.

**This command clears nothing.** Production runs on MongoDB Atlas, so there is no
container to wipe and `down -v` does not touch it. Starting a fresh MVP round
means emptying the database in Atlas yourself first; nothing in this repo deletes
data.

The individual steps are still available if you need one on its own — for
example, repairing a superadmin whose organization link is wrong:

```bash
docker compose -f compose.prod.yml -p qbank run --rm \
  api node dist/scripts/seed-superadmin.js
```

---

## Troubleshooting

**`Error error from registry: unauthorized` while pulling the image.** The
VPS hasn't logged in to GHCR yet — see the `docker login` step under *Set up
the application*. Confirm it's this and not a tag that never got pushed:
`docker pull <image>:<tag>` on the server as `VPS_USER` reproduces the same
error; a 401 `unauthorized` (rather than 404 `not found`) points at auth.
After `docker login ghcr.io`, retry the pull, then re-run the deploy.

**`docker login` succeeds but pulling still fails with `denied`.** Different
error from the one above — `unauthorized` (401) means bad/missing
credentials; `denied` (403) means the credentials are valid but lack
permission. `docker login` only checks that the PAT is real, not that it has
the right scope, so this combination is the classic sign of a PAT missing
the `read:packages` scope. Check what scopes a token actually has without
regenerating it: `curl -sSI -H "Authorization: token <PAT>" https://api.github.com/user | grep -i x-oauth-scopes`.
Fix: generate a **classic** PAT (not fine-grained) at
github.com/settings/tokens with `read:packages` checked, and log in again.

**Deploy failed at "Checking environment".** The output lists the missing keys.
Add them to `/opt/qbank/.env`. Nothing was changed — the running stack is
untouched.

**Deploy failed at "Waiting for the app to respond".** The new image is running
but not serving. The last 40 log lines are printed above the failure. Roll back
with the command the script prints, then investigate. On a brand-new server
check the order: the api has to be deployed before any app tier, because the
frontends are proved through their `/api` proxy. (`deploy.sh api` itself copes
with an empty server: it probes the api container directly when there is no
`web` yet, and says so.)

**Deploy failed at "Another deploy has held the lock for over 5 minutes."**
Another `deploy.sh` is still running, or one was killed in a way that left its
shell alive. Check with `ps aux | grep deploy.sh`. There is no stale lock to
clean up by hand — the kernel releases a `flock` when the holding process dies,
including on `kill -9` — so if nothing is running, simply retry.

**A container sits at `(unhealthy)`.** Read the last probe's actual output:

```bash
docker inspect --format '{{json .State.Health}}' qbank-api | jq
```

For `api` this almost always means `/api/readyz` is returning 503 because
MongoDB is unreachable — the process is fine, the database is not. Note that
nothing restarts an unhealthy container automatically; it is a signal, not a
remediation.

**The API container restarts in a loop.** Almost always a missing or malformed
env var — the app deliberately refuses to boot without `MONGODB_URI` and
`JWT_SECRET`. Check `docker compose -f compose.prod.yml -p qbank logs api`.

**502 on `/api` while the api container is healthy.** Applies to `web`,
`learner` and `writer` alike (the homepage has no `/api`; it answers 404
there by design). Their nginx resolves the api by name through Docker's embedded
DNS (`resolver 127.0.0.11` in `qbank-admin/nginx.conf`,
`qbank-learner/nginx.conf` and `qbank-writer/nginx.conf`) and re-resolves it every 10s, so a recreated
api container with a new IP is picked up on its own. A 502 in the ~10s right
after a deploy is that DNS cache expiring and is expected — the deploy probe
retries through it. A *persistent* 502 means the running web image predates that
change; redeploy that service to pick it up.

**Probing by hand from inside a web container.** Use `127.0.0.1`, not
`localhost`: Docker's `/etc/hosts` maps `localhost` to both `127.0.0.1` and
`::1`, BusyBox wget tries `::1` first, and nginx's `listen 80` binds IPv4 only,
so the `localhost` form is refused every time regardless of app state.

```bash
docker compose -f compose.prod.yml -p qbank exec -T web \
  wget -q -O- http://127.0.0.1/api/readyz

docker compose -f compose.prod.yml -p qbank exec -T learner \
  wget -q -O- http://127.0.0.1/api/readyz
```

**Malayalam PDF exports fail.** The admin and learner SPAs fetch their faces
from `/fonts/` at render time and neither has a CDN fallback, so a 404 on any of
them kills every export. There are **six** files in each, and two carry spaces
in the filename, requested `encodeURI`'d as `%20`. Check both tiers directly:

```bash
for svc in web learner; do
  docker compose -f compose.prod.yml -p qbank exec -T $svc \
    wget -S -q -O /dev/null "http://127.0.0.1/fonts/Century%20Schoolbook%20Std%20Regular.otf"
done
```

Expect `200 OK` and `Content-Type: font/otf`. A 404 means the `location ^~
/fonts/` block in that app's `nginx.conf` is missing or the files did not make it
into `dist/` — Vite copies `public/` verbatim, so they are unhashed and must be
present under that exact name.

> **Probe for a font that does not exist, too.** Until 2026-08-18 the admin image
> had no `/fonts/` block at all, so a missing `.otf` face fell through to the SPA
> catch-all and came back as **`index.html` with a 200**. react-pdf was handed a
> few kilobytes of HTML and failed deep inside fontkit, pointing nowhere near the
> cause. Both images now answer `404`:
>
> ```bash
> docker compose -f compose.prod.yml -p qbank exec -T web \
>   wget -S -q -O /dev/null "http://127.0.0.1/fonts/no-such-face.otf"   # must be 404
> ```
>
> Casing is load-bearing on the same probe: the Mandaram regular is `MANDARAM.ttf`
> and its bold cut `Mandaram-Bold.ttf`. The container filesystem is case-sensitive
> and developer machines are not, so a catalog string that drifts from the file
> passes locally and 404s only here.

The **writer** has its own `/fonts/` block and a smaller set, **two** files:
`MANDARAM.ttf` and `NotoSansMalayalam.ttf` (its fallback face). No Century
Schoolbook, no bold cut, so a `Mandaram-Bold.ttf` probe there 404s by design.
Both of its faces must answer `200` with `Content-Type: font/ttf`:

```bash
for face in MANDARAM.ttf NotoSansMalayalam.ttf; do
  docker compose -f compose.prod.yml -p qbank exec -T writer \
    wget -S -q -O /dev/null "http://127.0.0.1/fonts/$face"
done
```

**A frontend image fails to build with `ERR_PNPM_LOCKFILE_CONFIG_MISMATCH`.**
Its `Dockerfile` is not copying `pnpm-workspace.yaml` and `patches/` into the
install layer. Both SPAs patch `@react-pdf/layout` with a one-line inline-math
fix; pnpm 10 declares that in `pnpm-workspace.yaml` and records it in the
lockfile, so `pnpm install --frozen-lockfile` refuses to proceed without it. The
install layer needs all four manifests:

```dockerfile
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY patches ./patches
```

**Do not "fix" this by dropping `--frozen-lockfile`.** That installs the package
unpatched, the build goes green, every export succeeds, and every fraction and
subscript in every paper is silently misplaced by up to 4.49pt. Background:
[qbank-admin/docs/todos/frontend-image-build-patch-manifests.md](../qbank-admin/docs/todos/frontend-image-build-patch-manifests.md).

**`network traefik_proxy declared as external, but could not be found`.** The
Traefik stack hasn't been started on this server yet — it is what creates that
network. Bring it up first
(`ACME_EMAIL=… docker compose -f compose.traefik.yml -p traefik up -d`), then
retry the app stack.

**The seed run stops at `API did not become ready within 90s`.** Two causes, in
the order worth checking:

1. **The seed container is not on the api's network.** `compose.prod.yml` has no
   default network of its own — only the external `traefik_proxy` — so the `seed`
   service carries an explicit `networks: [traefik_proxy]`. Without it the
   container starts perfectly well, cannot resolve the name `api`, and fails 90
   seconds later with a message that reads like an API fault. Confirm with
   `docker compose -f compose.prod.yml -p qbank --profile seed config`
   and look for `traefik_proxy` under the `seed` service.
2. **The api genuinely is not ready.** `docker compose -f compose.prod.yml -p
   qbank ps` should show it `(healthy)`; if not, read
   `logs api` — a missing `MONGODB_URI` or `JWT_SECRET` is the usual answer.

A `Login failed (401)` immediately after is a different problem: the
`SEED_SUPERADMIN_USERNAME` / `SEED_SUPERADMIN_PASSWORD` in `.env` do not match the
account already in the database. The seeded account is pinned to a fixed `_id`,
so once it exists these two values no longer create it, they only sign in as it.

**`Local changes present in /opt/qbank — skipping git pull` on every
deploy, with `git status` showing nothing you edited.** Run `git diff` on the
server: if the only hunks are `old mode 100644` / `new mode 100755` on
`scripts/*.sh`, that is a file-mode diff, not a content one. It appears when the
scripts are committed without the executable bit (a Windows clone has
`core.fileMode=false`, so git never records it) and `setup-app.sh` then
`chmod +x`es them on the server, where `core.fileMode` is `true`. The checkout
is then permanently dirty and `deploy.sh` skips its config pull for good — so
the server keeps running old compose files while reporting a clean deploy. Fixed
in the repo by recording the bit (`git update-index --chmod=+x scripts/*.sh`);
to clear a server that is already in this state, drop the mode-only diff and
pull once by hand:

```bash
cd /opt/qbank
git diff --stat          # confirm it is mode-only before discarding anything
git checkout -- scripts/
git pull --ff-only
git status               # clean, and ls -l scripts/ shows 755
```

Do **not** "fix" this with `git config core.fileMode false` on the server — that
hides the symptom while leaving the scripts non-executable for anyone who clones
the repo fresh.

**`permission denied` on `git pull` or `.env` during a deploy.** `VPS_USER`
is not the account `/opt/qbank` belongs to. Compare `ls -ld
/opt/qbank` with the `VPS_USER` secret; re-running `setup-app.sh` as
the intended account prints the value it should be.

**Certificate is not issued.** Traefik needs the hostname's DNS record to
resolve to this server *before* it can complete the ACME challenge, and each
host is issued separately — so the admin can be fine while the learner is not.
Run `./scripts/check-hosts.sh` first: it compares the hostnames in `.env` with
`.env.example` and resolves each name (`<HOMEPAGE_HOST>` **and**
`www.<HOMEPAGE_HOST>`, which share one certificate and fail together, then
`<ADMIN_HOST>`, `<LEARNER_HOST>`, `<WRITER_HOST>`) against this server's
address. Then `docker logs traefik`.

Let's Encrypt allows **five failed authorizations per name per hour**; past
that, Traefik logs `429 ... rateLimited ... retry after <time>` and nothing
issues until then. Fix the cause before retrying, or each restart spends
another attempt. This happened on 2026-11-07, when the new server's `.env` said
`qfoundry.com` instead of `qfoundry.in`; that is why both deploy scripts now
run `check-hosts.sh` before recreating anything. Once `.env` is fixed, recreate
the containers so their `Host()` labels change: `docker compose -f
compose.prod.yml -p qbank up -d`.

**Which build is live?** The version string is rendered in the app's sidebar
footer. `GET /api/readyz` also returns the API's `buildId`.

---

## Known constraints

- **Run exactly one `api` container.** The AI-tagging queue worker holds an
  in-process lock; a second replica would double-process the queue. Scaling
  needs a distributed lock (a Mongo lease document) first.
- **No monitoring yet.** Container logs are rotated (10 MB × 3), and all five
  services report real health to Docker — so `docker ps` is a truthful
  local signal, but nothing is watching it and nothing acts on it. Compose does
  not restart an unhealthy container. A log shipper and an external uptime check
  are still additive work. Whenever that happens, the acceptance test is *"a log
  line from the app appears in the dashboard"* — the predecessor project's Loki
  pipeline was installed but silently dropping everything for a year.
- **Back up the `letsencrypt` volume.** It holds `acme.json`. Losing it means
  re-issuing certificates and risking Let's Encrypt rate limits.
- **MongoDB is Atlas**, so database backups are Atlas's job, not this repo's.
