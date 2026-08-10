# NEW-MACHINE-SETUP.md — Editing the Sierra Dashboard from a new laptop

This is the setup for a machine where you want to **edit the project and push changes with Git**
(so `git pull` / `git push` work, and pushing deploys the live site).

> **Which guide do I want?**
> - **Just run it as a wall display** (no Git, no editing) → use **`SETUP-ON-NEW-PC.md`** instead.
> - **Edit the project and push changes from here** → this guide.

**Repo:** https://github.com/TroyPutman/sierra-dashboard (public) · **Branch:** `main`
No coding knowledge needed — just follow the steps in order. Plan on ~15 minutes.

---

## 1. Prerequisites — install these first

### PowerShell (already on Windows — nothing to install)
The dashboard runs on **Windows PowerShell 5.1**, which is built into Windows.
- **Check it:** open the Start menu, type **PowerShell**, open **Windows PowerShell**, and run:
  ```
  $PSVersionTable.PSVersion
  ```
  Any **5.1.x** is fine. (PowerShell 7 / `pwsh` is optional — the cloud automation uses it, but you don't need it locally.)

### Git (NOT built in — you must install it)
This is the one real install.
1. Download **Git for Windows**: https://git-scm.com/download/win
2. Run the installer and **accept all the default options** (the defaults include *Git Credential Manager*, which stores your GitHub login safely — you want that).
3. **Check it:** open a **new** PowerShell window and run:
   ```
   git --version
   ```
   You should see something like `git version 2.46.0.windows.1`. If "git is not recognized," close and reopen PowerShell (or restart the PC) so it picks up the new install.

---

## 2. Get the project onto this machine

You have two options — either is fine:

**Option A — copy the folder (if you already copied `st-dashboard` over).**
If you copied the *entire* folder (including its hidden `.git` sub-folder), the Git connection came with it. Skip to Step 3. *(If push/pull later complain there's no remote, use Option B instead.)*

**Option B — clone a fresh copy (cleanest).**
Open PowerShell, go to where you want the project (Desktop here), and clone:
```
cd $HOME\Desktop
git clone https://github.com/TroyPutman/sierra-dashboard.git
cd sierra-dashboard
```
The first time it talks to GitHub it will ask you to sign in — do **Step 3** first (create the token), then come back and it'll accept it.

---

## 3. Git authentication — Personal Access Token (PAT)

GitHub no longer accepts your account password from Git. You use a **token** instead, with the
**`repo`** and **`workflow`** permissions (same as before). `workflow` is required because this repo
contains GitHub Actions files — without it, pushing any change under `.github/workflows/` is rejected.

### 3a. Create the token on GitHub
1. Go to https://github.com and sign in as the account that owns the repo.
2. Click your **avatar** (top-right) → **Settings**.
3. Left sidebar, scroll to the bottom → **Developer settings**.
4. **Personal access tokens** → **Tokens (classic)**.
5. **Generate new token** → **Generate new token (classic)**. (Confirm your password if asked.)
6. Fill in:
   - **Note:** something like `sierra-dashboard – <this laptop's name>`.
   - **Expiration:** your call. Pick **No expiration** for a set-and-forget wall PC, or e.g. 90 days if you prefer to rotate it.
   - **Scopes:** tick **`repo`** (the whole top box) **and** **`workflow`**. Leave everything else unticked.
7. Click **Generate token** at the bottom.
8. **Copy the token now** (it starts with `ghp_…`). GitHub shows it **only once** — paste it into Notepad temporarily so you don't lose it. Treat it like a password.

### 3b. Give the token to Git (pick ONE method)

**Method 1 — put the token in the connection URL (simplest, always works).**
In the project folder, run this once (replace `YOUR_TOKEN` with the `ghp_…` value):
```
git remote set-url origin https://TroyPutman:YOUR_TOKEN@github.com/TroyPutman/sierra-dashboard.git
```
Now `git pull` / `git push` just work, no prompts.
- *Security note:* the token is saved in plain text in this folder's `.git\config`. That's fine on **your own** laptop — just don't share that file or screenshots of `git remote -v` (which would show the token). You can revoke/replace a token anytime on GitHub.
- If you set an expiration, re-run this same command with a fresh token when the old one lapses.

**Method 2 — let Windows store it securely (more secure, recommended if you're comfortable).**
Just run a Git command that needs GitHub, e.g.:
```
git pull
```
A **"Sign in to GitHub"** window pops up (Git Credential Manager):
- If it offers a **"Token" / "Personal access token"** field → paste your token → Sign in.
- If instead the *terminal* asks: **Username** = your GitHub username (`TroyPutman`); **Password** = **paste the token** (not your real password).

Windows then remembers it (encrypted, in Windows Credential Manager) and won't ask again.

### 3c. Confirm auth works
```
git pull
```
You should see **`Already up to date.`** (or it pulls a few changes) with **no** authentication error.
If it says *"Authentication failed,"* the token is wrong/expired or missing the `repo` scope — redo 3a/3b.

---

## 4. Turn the commit-safety guard back on (one-time, important)

This project has a rule: **manual commits are code-only.** A background cloud job owns the `data/`
folder and commits data there itself. A local hook enforces this — **but Git does not carry hook
settings across a clone or a folder copy**, so you must switch it on once, in the project folder:
```
git config core.hooksPath .githooks
```
Confirm it took (should print `.githooks`):
```
git config --get core.hooksPath
```
If you skip this, you can accidentally commit `data/` files, which then collide with the cloud job's
commits and cause push/pull conflicts. (See Step 5 for the rule this protects.)

---

## 5. Verify it runs and reaches ServiceTitan

`secrets.json` holds the ServiceTitan credentials. You said it's already copied over — first
**confirm the file `secrets.json` exists** in the project folder.
> If it's missing, create it: it's a small file with four values — `clientId`, `clientSecret`,
> `appKey`, `tenantId` (tenantId is `1066404518`). Full step-by-step is in **`SETUP-ON-NEW-PC.md`,
> Step 3**. Note: `secrets.json` is git-ignored and will **never** be committed.

Start the local server from the project folder:
```
powershell -ExecutionPolicy Bypass -File serve.ps1
```
Success looks like:
```
Sierra dashboard server running.
Open in your browser:  http://localhost:8787
Press Ctrl+C to stop.
```
Open **http://localhost:8787** in a browser. Numbers appearing means the **ServiceTitan connection
works from this machine**.
- **First view of a day/month takes 1–2 minutes** while it pulls fresh data (the SILO month ~2 min). That's normal, not a freeze. It's cached and fast afterward.
- If you see **"COULD NOT LOAD DATA"** or an error mentioning `secrets.json`: the credentials file is missing or has a wrong value, or the PC is offline. See the Troubleshooting section of `SETUP-ON-NEW-PC.md`.
- Stop the server with **Ctrl+C** in the PowerShell window.

---

## 6. Project-specific things that trip people up on a new machine

- **Never `git add data/` by hand.** The cloud workflow owns `data/` (it commits the heartbeat +
  frozen snapshots itself). The hook from Step 4 blocks it. If you *ever* truly need to, override with
  `ALLOW_DATA_COMMIT=1 git commit …` — but normally, don't.

- **Pull before you push — a rejected push is normal here.** The cloud job commits to the repo
  roughly **every 15 minutes**, so your branch often falls "behind" and a push gets rejected. The fix
  is always the same:
  ```
  git pull
  git push
  ```
  Your code and the robot's `data/` never touch the same files, so the pull merges cleanly — it's not
  a real conflict, just the two of you taking turns.

- **Pushing to `main` deploys the live site.** A push triggers the GitHub Actions workflow
  (refresh → build → publish to GitHub Pages at https://troyputman.github.io/sierra-dashboard/).
  After pushing, check the repo's **Actions** tab and wait for the run to go **green** before assuming
  it's live.

- **"LF will be replaced by CRLF" warnings are harmless.** Windows Git prints these on commit — ignore them.

- **"STALE CODE" banner in the dashboard.** `serve.ps1` loads its PowerShell code once at startup.
  If you edit `serve.ps1` or anything in `lib/` **while it's running**, the page shows a *STALE CODE*
  warning — press **Ctrl+C** and start `serve.ps1` again to load your changes.
  *Editing `dashboard.html` does NOT need a restart* — it's re-served on every request; just refresh the browser.

- **`secrets.json` never leaves this machine.** It's git-ignored on purpose. Don't email it, don't put
  it in a shared drive, and don't paste the values into chat.

- **No Node.js or Python needed.** The whole project is PowerShell — if a guide elsewhere mentions
  `node` or `python`, it doesn't apply here.

---

**Quick recap:** install Git → make a `repo`+`workflow` token → point Git at it (Step 3b) →
`git config core.hooksPath .githooks` → run `serve.ps1` and open `localhost:8787`. Then edit,
`git pull`, `git push` — and watch the Actions run go green.
