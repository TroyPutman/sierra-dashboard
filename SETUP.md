# SETUP — Take the Sierra Morning Dashboard live (GitHub Pages, fully public)

This guide is written for a **non-technical** person. Follow the steps **in order**.
By the end you will have a live dashboard that:

- refreshes itself automatically during business hours,
- is hosted for **free** on **GitHub Pages**, and
- is **fully public** — there is **no login, no password, no gate of any kind**.

**Important facts before you start:**

- **This is a fully public dashboard, on purpose.** GitHub Pages is free only for **public**
  repositories. Making the repo public means **anyone with the link — and search engines —
  can see the dashboard AND the raw data files behind it.** Those `data/*.json` files include
  **technician names and their performance numbers.** This matches the fully-public, no-login
  choice that has already been made and accepted. If that is not acceptable, stop here — a
  public GitHub Pages site is not the right host.
- Your ServiceTitan credentials live in a file called `secrets.json`. That file is
  **gitignored** — it is **never** uploaded to GitHub, even though the repo is public. You
  paste those four values into GitHub's encrypted **Secrets** area instead (Step 4). The
  workflow rebuilds `secrets.json` on the fly at deploy time and never commits it.

---

## Step 1 — Install the tools

You can do almost everything through websites. The only thing that needs your PC is the
**first push** of the code to GitHub, which needs Git.

- **Git** (required once): https://git-scm.com/downloads — install with all default options.
- A free **GitHub account**: https://github.com/signup

(There is **no** Cloudflare account and **no** hosting bill — GitHub Pages hosts it for free.)

---

## Step 2 — Create the GitHub repo and push this project

1. On GitHub, click **New repository**.
   - Name it e.g. `sierra-dashboard`.
   - You can create it **Private** for now and flip it to Public in Step 3, or create it
     **Public** immediately — either is fine. (Free GitHub Pages needs it to end up Public.)
   - Do **not** add a README/.gitignore/license (this project already has them).
   - Click **Create repository**. Leave that page open — you'll copy the URL from it.

2. On your PC, open **PowerShell in the project folder**
   (`C:\Users\TroyP\Downloads\st-dashboard`) and run these commands one at a time.
   Replace `<YOUR-USERNAME>` and `<REPO-NAME>` with your values:

   ```powershell
   git init
   git add .
   git commit -m "Initial dashboard"
   git branch -M main
   git remote add origin https://github.com/<YOUR-USERNAME>/<REPO-NAME>.git
   git push -u origin main
   ```

   > **SECRETS SAFETY:** `secrets.json` is listed in `.gitignore`, so `git add .` will
   > **skip it automatically**. Do **NOT** run `git add -f secrets.json` or
   > `git add --force` — that would override the ignore and leak your credentials.
   > After the push, open the repo on GitHub and confirm `secrets.json` is **not** in the
   > file list. (You should see `secrets.example.json` but **never** `secrets.json`.)

   > If GitHub later says your default branch is `master` instead of `main`, open
   > `.github/workflows/deploy.yml` and change the `branches: ["main"]` line to
   > `branches: ["master"]`.

---

## Step 3 — Make the repo PUBLIC

Free GitHub Pages requires a **public** repository. If you created the repo as Public in
Step 2, you can skip ahead — but read the warning below first.

1. On GitHub, go to **Repo → Settings → General**.
2. Scroll to the bottom, to the **Danger Zone**.
3. Click **Change repository visibility → Change to public**, and confirm.

> **What "public" means here — read carefully.** After this, the **code AND the committed
> `data/*.json` files are publicly browsable on GitHub** by anyone, and once the site is live
> the dashboard and those same data files are readable by **anyone with the URL and by search
> engines**. Those data files include **technician names and their performance numbers**.
> There is **no login and no password** protecting any of it. This is the intended,
> already-accepted design for this dashboard.

---

## Step 4 — Add the GitHub Actions secrets

These are the encrypted values the automatic deploy uses. On GitHub:

**Repo → Settings → Secrets and variables → Actions → "New repository secret"**

Add these **four** secrets — and **only** these four. Every value comes straight from your
local `secrets.json` file — open it in Notepad and copy each value.

| Secret name        | Where the value comes from                     |
|--------------------|------------------------------------------------|
| `ST_CLIENT_ID`     | `clientId` in your local `secrets.json`        |
| `ST_CLIENT_SECRET` | `clientSecret` in your local `secrets.json`    |
| `ST_APP_KEY`       | `appKey` in your local `secrets.json`          |
| `ST_TENANT_ID`     | `tenantId` in your local `secrets.json`        |

The names must match **exactly** (uppercase, with underscores).

> **No other secrets are used.** There are **no Cloudflare secrets** (no
> `CLOUDFLARE_API_TOKEN`, no `CLOUDFLARE_ACCOUNT_ID`) and **no `DASH_PASSWORD_HASH`** — the
> dashboard has no login gate at all. If you still have any of those secrets from an earlier
> setup you can safely delete them; nothing reads them anymore.

---

## Step 5 — Enable GitHub Pages

1. On GitHub, go to **Repo → Settings → Pages**.
2. Under **Build and deployment → Source**, choose **GitHub Actions**.

That's it — you do not pick a branch or folder. The workflow in this project publishes the
site for you.

---

## Step 6 — Trigger the first deploy

Two ways — either works:

- **Automatic:** you already pushed in Step 2, which starts a deploy. Or push any small
  change later. (If the repo wasn't public yet when you pushed, just make it public per
  Step 3, then use the manual option below.)
- **Manual:** **Repo → Actions → "Deploy dashboard to GitHub Pages" → "Run workflow"**.

Watch it under the **Actions** tab. A green check means it built the site and published it to
GitHub Pages. If it fails, click the run to read the error (the workflow **fails loudly**
rather than publish a broken page — e.g. if a secret is missing).

---

## Step 7 — Your live URL

Once the deploy succeeds, your dashboard is at:

```
https://<your-github-username>.github.io/<repo-name>/
```

For this project (username **TroyPutman**, repo **sierra-dashboard**) that is:

```
https://troyputman.github.io/sierra-dashboard/
```

> On the **first** deploy it can take a couple of minutes for the URL to start working
> after the Actions run turns green. After that, updates appear within a minute or two of
> each deploy.

> **There is NO login and NO gate.** The dashboard **and** its underlying `data/*.json`
> files are fully public to **anyone with the URL and to search engines**. Do not put
> anything at this URL that you are not comfortable being completely public.

---

## Everyday operation

- **Any code change you push auto-redeploys.** Just `git add` / `git commit` / `git push`
  and GitHub rebuilds and republishes within a few minutes (the workflow runs on every push
  to your default branch).
- **Automatic refresh schedule.** The dashboard reruns itself about **every 30 minutes,
  roughly 6 AM–4:30 PM Pacific, Monday–Saturday** (the exact clock time shifts by 1 hour
  between summer and winter because GitHub's scheduler runs in UTC).
- **The schedule stays alive on its own.** Every run writes a small heartbeat file
  (`data/last-refresh.txt`) and commits it back to the repo, so GitHub always sees recent
  activity and **never auto-disables** the scheduled workflow (GitHub otherwise pauses
  schedules after 60 days of no commits). These commits use `[skip ci]`, so they do **not**
  re-trigger the workflow — no runaway loop.

### Changing the refresh frequency

Because this repo is **public**, GitHub Actions minutes are **free and unlimited** — running
more often costs nothing (a nice upgrade from the old private-repo 2,000-minutes/month quota).
Frequency is now purely about how fresh you want the numbers, not about cost.

To change it, edit the **`cron:`** line near the top of `.github/workflows/deploy.yml`:

```yaml
schedule:
  - cron: "0,30 13-23 * * 1-6"
```

- **Refresh less often:** change `0,30` to `0` (hourly), or shorten the hour range
  (e.g. `14-22`), or use `1-5` for Monday–Friday only.
- **Once a day:** `0 14 * * 1-5` runs once each weekday morning.
- **Refresh more often:** add minute marks, e.g. `0,15,30,45`.

The workflow file has a full comment block explaining the cadence right above the `cron` line.

---

## Repo hygiene / avoiding data conflicts

- **Manual commits are code-only.** The scheduled workflow (`.github/workflows/deploy.yml`)
  owns `data/` — it commits back only the heartbeat (`data/last-refresh.txt`) and any
  newly-**frozen** (`"final": true`) snapshot/cache files. Today's live snapshot and the
  current/previous-month revenue caches are volatile (`"final": false"`, rebuilt every run)
  and are never committed by the workflow, on purpose — committing those every run used to
  collide with manual commits and produce merge conflicts on `data/*.json`.
- **A pre-commit guard enforces this locally.** `.githooks/pre-commit` blocks a manual
  commit if any staged path is under `data/`. On a **fresh clone**, this hook is not active
  until you run, once:
  ```powershell
  git config core.hooksPath .githooks
  ```
  After that, `git commit` will refuse (with an explanatory message) if it finds a staged
  `data/*.json` or `data/last-refresh.txt` file.
- **Override, if you really mean to commit a data file locally:**
  ```powershell
  $env:ALLOW_DATA_COMMIT = "1"; git commit -m "..."
  ```
  or bypass the hook entirely with `git commit --no-verify`. The workflow's own commits
  always pass (it runs in CI, which the hook detects via `GITHUB_ACTIONS`/`CI`).

---

## Goal editing (Cloudflare Worker + KV)

The dashboard can show **editable goal progress bars** on four metrics: **Plumbing revenue (MTD)**,
**HVAC Sales sold (MTD)**, **Calls booked (today)**, and **SILO flip rate (MTD)**. Everyone can see the
bars; changing a goal number requires a shared **edit password** that is checked on a small server
(a free Cloudflare Worker), so the password never lives inside the public web page.

**This whole feature is optional.** If you skip it, the dashboard works exactly as before with **no goal
bars and no errors**. You only need it if you want on-screen goals people can edit.

You do this once. It needs a **free** Cloudflare account (the free tier is far more than enough here).

### 1. Create / sign in to Cloudflare
Go to https://dash.cloudflare.com and sign up (or log in). Free plan is fine.

### 2. Create the KV namespace (where goals are stored)
In the dashboard: **Storage & Databases → KV → Create a namespace**. Name it e.g. `sierra-goals`.
Copy the **namespace ID** it shows you — you'll need it in a moment.

### 3. Deploy the Worker — pick ONE path

**Path A — all in the browser (no installs):**
1. **Workers & Pages → Create → Create Worker**. Give it a name, e.g. `sierra-goals`. Click **Deploy**.
2. Click **Edit code**, delete the sample, and paste the full contents of `goals-worker/worker.js`
   from this project. Click **Deploy** again.
3. **Settings → Bindings → Add → KV namespace.** Set **Variable name** to exactly `GOALS` and pick the
   namespace you made in step 2. Save.
4. **Settings → Variables and Secrets → Add** a secret named exactly `EDIT_PASSWORD`, type your chosen
   password, mark it **Encrypt**, and save. (This is the shared password people will type to edit a goal.)

**Path B — command line (`wrangler`):** from the `goals-worker/` folder:
```
wrangler login
wrangler kv namespace create GOALS      # copy the printed id...
# ...paste that id into goals-worker/wrangler.toml (the id = "..." line)
wrangler deploy
wrangler secret put EDIT_PASSWORD        # type the shared edit password when prompted
```

### 4. Copy the Worker URL into the dashboard
After deploy, Cloudflare shows your Worker URL, e.g. `https://sierra-goals.<your-subdomain>.workers.dev`.
Open `dashboard.html`, find the line near the top of the `<script>`:
```
const GOALS_API = '';   // <-- paste your Cloudflare Worker URL here
```
and paste your URL between the quotes:
```
const GOALS_API = 'https://sierra-goals.<your-subdomain>.workers.dev';
```
Commit + push (or re-run the deploy). The goal bars now appear for everyone; clicking a bar asks for the
edit password before saving. A correct password saves to Cloudflare KV and is visible to everyone on the
next load; a wrong password is rejected and nothing changes.

**Goal keys** (stored in KV; only relevant if you inspect the data): `plumbing-rev-mtd`, `hvac-sales-mtd`,
`calls-booked-today`, `silo-flip-mtd`.

---

## Troubleshooting

- **Actions run failed on "Reconstruct secrets.json":** one of `ST_CLIENT_ID`,
  `ST_CLIENT_SECRET`, `ST_APP_KEY`, or `ST_TENANT_ID` is missing/blank in repo secrets
  (Step 4).
- **Actions run failed on "Deploy to GitHub Pages":** confirm **Settings → Pages → Source**
  is set to **GitHub Actions** (Step 5), and that the repo is **public** (Step 3). Pages will
  not publish for a private repo on the free plan.
- **The Pages URL shows a 404 for a minute or two after a green run:** normal on the very
  first deploy — wait a couple of minutes and refresh.
- **`secrets.json` showed up on GitHub:** remove it immediately and rotate those ServiceTitan
  credentials — it should never appear (it's gitignored; you likely force-added it). This
  matters even more now that the repo is public.
