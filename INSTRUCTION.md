# Server preparation notes

Working notes for the steps that happen **before** the application exists on a
server — hardening the box, installing Docker, and getting SSH access working.

These sit outside [README.md](README.md) on purpose. Nothing in this repo
provisions a server (see the README's *Prerequisites* table for what must
already be true); this file is just the running record of how that provisioning
was done, so it can be repeated on the next box.

Order matters: **0 → 1 → 2 → 3**, then [Set up the application](#4-set-up-the-application).

---

## 0. Start DNS early

DNS is the one step that does not wait for you: Let's Encrypt cannot issue a
certificate until the name resolves to the new server, and propagation takes
anywhere from minutes to a day. Create the records as soon as the VPS has an IP,
low TTL, all A records on that IP:

| Record | Serves |
|---|---|
| `qfoundry.in` (`@`) | the marketing site (`HOMEPAGE_HOST`) |
| `www.qfoundry.in` | same router; redirects to the apex. **Shares the apex's certificate**, so both must resolve |
| `studio.qfoundry.in` | the staff back office (`ADMIN_HOST`) |
| `prep.qfoundry.in` | the learner app (`LEARNER_HOST`) |
| `writer.qfoundry.in` | the writer portal (`WRITER_HOST`) |

Check from anywhere before the first deploy:

```bash
dig +short qfoundry.in www.qfoundry.in studio.qfoundry.in prep.qfoundry.in writer.qfoundry.in
```

Expect the new server's IP five times.

---

## 1. Harden the VPS and install Docker

Reference walkthrough: <https://tonyteaches.tech/install-docker-ubuntu-vps/>

```bash
curl -fsSL https://raw.githubusercontent.com/tonyflo/ttt-vps-scripts/main/setup-docker.sh | bash
```

Installs Docker Engine with the Compose plugin — the two things
`scripts/setup-app.sh` checks for and refuses to install itself.

> ⚠ This is a third-party script piped into a shell. Read it first
> (`curl -fsSL <url> | less`) before running it on a box you care about.

**Verify the firewall before moving on.** Whatever the hardening left behind,
three ports must be open: 22 (SSH, and GitHub Actions deploys over it), 80 and
443 (Traefik; plain HTTP only redirects to HTTPS). These are the README's
*Prerequisites* rows that no script in this repo will ever touch.

```bash
sudo ufw status verbose        # or whatever firewall the script configured
```

Expect `22/tcp`, `80/tcp` and `443/tcp` allowed. If `ufw` is active and a port
is missing: `sudo ufw allow 80/tcp && sudo ufw allow 443/tcp`. Also make sure
the provider's own firewall (cloud console security group) allows the same
three, or the box is open and still unreachable.

---

## 2. SSH keys

Generate a dedicated key — one per purpose, never a reused personal key. This
one is for *you* to administer the box; the CI deploy key comes later and is a
different key.

```bash
ssh-keygen -o -a 100 -t ed25519 -f ~/.ssh/qfoundry-vps -C "you@example.com qfoundry-vps"
```

| Flag | Meaning |
|---|---|
| `-o` | Write in the newer OpenSSH private-key format (implied for `ed25519`, harmless to state) |
| `-a` | KDF rounds for the passphrase — higher is slower to brute-force |
| `-t` | Key type: `dsa \| ecdsa \| ecdsa-sk \| ed25519 \| ed25519-sk \| rsa` |
| `-f` | Output keyfile — writes `~/.ssh/qfoundry-vps` and `~/.ssh/qfoundry-vps.pub` |
| `-C` | Comment, so the key is identifiable in `authorized_keys` |

Install the **public** half on the server, as the account that will own
`/opt/qbank` and that CI will later connect as (a dedicated service account is
preferred; `root` works):

```bash
ssh-copy-id -i ~/.ssh/qfoundry-vps <account>@<vps-ip>   # -i = identity file
```

Then log in with it:

```bash
ssh -i ~/.ssh/qfoundry-vps <account>@<vps-ip>
```

Optional, so the rest of these notes can say `ssh qfoundry`:

```
# ~/.ssh/config
Host qfoundry
  HostName <vps-ip>
  User <account>
  IdentityFile ~/.ssh/qfoundry-vps
```

The CI deploy key is a **separate** key from this one — generated locally and
handed over as a public half only, installed on the *same* account. See *Set up
the application* in [README.md](README.md#set-up-the-application).

---

## 3. Docker permissions

The account that deploys has to reach the Docker socket. The supported way is
group membership:

```bash
sudo groupadd docker            # usually already exists after step 1
sudo usermod -aG docker ${USER}
```

**Log out and back in** afterwards — group membership is only picked up on a new
login session, so `docker info` keeps failing in the shell that ran `usermod`.

```bash
sudo chmod 666 /var/run/docker.sock
```

> ⚠ Last resort only. This makes the Docker socket world-writable, which is
> effectively root on the host for every local account, and it resets on reboot.
> Use it to unblock a session, then fix the group membership properly.

Verify before moving on — this is exactly what `setup-app.sh` probes:

```bash
docker info
```

---

## 4. Set up the application

Once the above holds, the server is ready for the one-time application setup.
Run it **as the account CI will connect as** (the one from step 2):

```bash
curl -fsSL https://raw.githubusercontent.com/mroshan74/qbank-deploy/main/scripts/setup-app.sh | bash
```

It checks its prerequisites, clones this repo to `/opt/qbank`, creates
`.env` from the template, and prints the remaining manual steps (also saved to
`/opt/qbank/REMAINING-STEPS.txt`). Safe to re-run.

What those remaining steps amount to, so nothing is a surprise:

- **`.env`** needs the **four** hostnames from step 0 (`HOMEPAGE_HOST`,
  `ADMIN_HOST`, `LEARNER_HOST`, `WRITER_HOST`), `CLIENT_URL` naming the three
  *app* origins (studio, prep, writer; not the homepage), the database and API
  secrets, the SMS provider, and the seed account. `deploy.sh` refuses to run
  while any key from `.env.example` is missing.
- **GitHub secrets** (`VPS_HOST`, `VPS_USER`, `VPS_SSH_KEY`,
  `VPS_SSH_KEY_PASSPHRASE`) go on **all five** app repos: `qbank-api`,
  `qbank-admin`, `qbank-learner`, `qbank-writer`, `qbank-homepage`.
- **Traefik** comes up before the app stack; it owns the shared network.
- **GHCR login** once, on this account; the five packages are private.

Full details: [README.md → Set up the application](README.md#set-up-the-application).

---

## 5. Bring the app up

Everything above happens **once per box**. Bringing the application up — Traefik,
the five-service app stack, then the one-command seed — happens on every fresh
MVP round, and lives in its own file: **[QUICKSTART.md](QUICKSTART.md)**,
commands only, in paste order. For a brand-new server its section
[First deploy on a new server](QUICKSTART.md#first-deploy-on-a-new-server-the-qfoundryin-hosts)
fixes the order: push `qbank-deploy`, run `setup-app.sh`, Traefik, secrets, then
the five app repos in order (`qbank-api` first), seed, verify.
