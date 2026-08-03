# SETUP — Take the Sierra Morning Dashboard live (Cloudflare Workers + Cloudflare Access)

This guide is written for a **non-technical** person. Follow the steps **in order**.
By the end you will have a live dashboard that:

- refreshes itself automatically during business hours,
- is hosted for free on **Cloudflare Workers**, and
- is protected by a real **login gate (Cloudflare Access)** — people sign in with an
  emailed one-time PIN, and only email addresses **you** approve can get in.

**Important safety facts before you start:**

- Your ServiceTitan credentials live in a file called `secrets.json`. That file is
  **gitignored** — it will **never** be uploaded to GitHub. You paste those values into
  GitHub's encrypted **Secrets** area instead (Step 4).
- There is **no site password to manage anymore.** The old client-side password gate is
  gone. **Cloudflare Access** is the login gate now, and it protects **everything** behind
  the URL — including the raw `data/*.json` files, not just the front page.
- Access is a real identity gate: unapproved people never see any numbers, even if they
  have the link.

---

## Step 1 — Install the tools

You can do almost everything through websites. The only thing that needs your PC is the
**first push** of the code to GitHub, which needs Git.

- **Git** (required once): https://git-scm.com/downloads — install with all default options.
- A free **GitHub account**: https://github.com/signup
- A free **Cloudflare account**: https://dash.cloudflare.com/sign-up

---

## Step 2 — Create a PRIVATE GitHub repo and push this project

1. On GitHub, click **New repository**.
   - Name it e.g. `st-dashboard`.
   - Set visibility to **Private**.
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

## Step 3 — Create your Cloudflare API token and find your Account ID

The GitHub workflow needs to deploy to Cloudflare on your behalf, so it needs a token.

### 3a — API token

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click **Create Token**.
3. Use the **"Edit Cloudflare Workers"** template (click **Use template**).
   - This grants the permissions Wrangler needs to deploy a Worker.
   - (If you build your own token instead, the minimum is **Account → Workers Scripts →
     Edit**, plus the account/zone **read** permissions the template already includes.)
4. Under **Account Resources**, select **your account**.
5. Click **Continue to summary → Create Token**.
6. **Copy the token now** — Cloudflare shows it only once. You'll paste it into GitHub in
   Step 4 as `CLOUDFLARE_API_TOKEN`.

### 3b — Account ID

1. Go to your Cloudflare dashboard home: https://dash.cloudflare.com/
2. Pick your account. On the account's **Workers & Pages** overview (right-hand side, or
   under the account details), find **Account ID** and click to copy it.
3. You'll paste this into GitHub in Step 4 as `CLOUDFLARE_ACCOUNT_ID`.

---

## Step 4 — Add the GitHub Actions secrets

These are the encrypted values the automatic deploy uses. On GitHub:

**Repo → Settings → Secrets and variables → Actions → "New repository secret"**

Add these **six** secrets. The first four come straight from your local `secrets.json`
file — open it in Notepad and copy each value. The last two come from Step 3.

| Secret name              | Where the value comes from                              |
|--------------------------|---------------------------------------------------------|
| `ST_CLIENT_ID`           | `clientId` in your local `secrets.json`                 |
| `ST_CLIENT_SECRET`       | `clientSecret` in your local `secrets.json`             |
| `ST_APP_KEY`             | `appKey` in your local `secrets.json`                   |
| `ST_TENANT_ID`           | `tenantId` in your local `secrets.json`                 |
| `CLOUDFLARE_API_TOKEN`   | The API token from Step 3a                               |
| `CLOUDFLARE_ACCOUNT_ID`  | The Account ID from Step 3b                              |

The names must match **exactly** (uppercase, with underscores).

> **`DASH_PASSWORD_HASH` is NO LONGER used.** The old client-side password gate has been
> replaced by Cloudflare Access. If you still have that secret from an earlier setup you can
> safely delete it — nothing reads it anymore.

---

## Step 5 — Trigger the first deploy

Two ways — either works:

- **Automatic:** you already pushed in Step 2, which starts a deploy. Or push any small
  change later.
- **Manual:** **Repo → Actions → "Deploy dashboard to Cloudflare Workers" → "Run workflow"**.

Watch it under the **Actions** tab. A green check means it built the site and deployed to
Cloudflare. If it fails, click the run to read the error (the workflow **fails loudly**
rather than publish a broken page — e.g. if a secret is missing).

---

## Step 6 — Your live URL

Once the deploy succeeds, your dashboard is at a `workers.dev` address that looks like:

```
https://sierra-dashboard.<your-account-subdomain>.workers.dev/
```

- `sierra-dashboard` is the Worker **name** (set by `name = ...` in `wrangler.toml`).
- `<your-account-subdomain>` is your personal Workers subdomain (Cloudflare assigns it the
  first time you deploy). You can see the exact URL in **Cloudflare dashboard → Workers &
  Pages → sierra-dashboard**.

> Right now this URL is **wide open** to anyone who has it. The very next step locks it down.
> Do Step 7 before you share the link.

---

## Step 7 — Turn on the login gate (Cloudflare Access)

This is what replaces the old password. It makes people sign in before they can see
**anything** at the URL.

### 7a — Enable Access on the Worker

1. **Cloudflare dashboard → Workers & Pages → `sierra-dashboard` → Settings →
   Domains & Routes.**
2. Find the `workers.dev` route and choose **Enable Cloudflare Access**.
   - This automatically creates a matching **Access application + policy** in Cloudflare's
     **Zero Trust** area for you. You'll refine that policy next.

### 7b — Set the login method and the allow-list

1. Go to **Cloudflare dashboard → Zero Trust → Access → Applications**.
2. Open the application that matches your `sierra-dashboard.<...>.workers.dev` URL
   (it was auto-created in 7a).
3. Edit its **policy** (the default one) so it is an **Allow** policy configured like this:
   - **Login method / identity:** **One-time PIN** (email). This makes Access email a
     6-digit code to whoever is trying to sign in — no accounts or passwords to manage.
   - **Include rule:** **Emails** → add the specific addresses that are allowed in
     (for example `troyp.sierrallc@gmail.com` and anyone else on your approved list).
     Only these addresses can receive a working PIN.
4. **Save.**

**To add or remove who can see the dashboard later:** come back to
**Zero Trust → Access → Applications → (this app) → Policies**, edit the **Emails** list in
the Include rule, and save. Adding an email lets that person in on their next sign-in;
removing one locks them out immediately.

> **Access protects EVERYTHING behind the URL** — the front page **and** every
> `data/*.json` file the dashboard loads. There is no way to reach the raw numbers without
> passing the Access login first. That is the whole point of using it instead of the old
> in-page password.

---

## Step 8 — Share it

Send your approved people the `workers.dev` URL. When they open it the first time they'll
enter their email, get a one-time PIN by email, type it in, and they're in. No password to
remember or leak.

---

## Everyday operation

- **Any code change you push auto-redeploys.** Just `git add` / `git commit` / `git push`
  and Cloudflare rebuilds/redeploys within a few minutes (the workflow runs on every push
  to your default branch).
- **Automatic refresh schedule.** The dashboard reruns itself about **every 30 minutes,
  roughly 6 AM–4:30 PM Pacific, Monday–Saturday** (the exact clock time shifts by 1 hour
  between summer and winter because GitHub's scheduler runs in UTC).
- **The schedule stays alive on its own.** Every run writes a small heartbeat file
  (`data/last-refresh.txt`) and commits it back to the repo, so GitHub always sees recent
  activity and **never auto-disables** the scheduled workflow (GitHub otherwise pauses
  schedules after 60 days of no commits). These commits use `[skip ci]`, so they do **not**
  re-trigger the workflow — no runaway loop, no wasted minutes.

### Changing the refresh frequency (and the cost tradeoff)

This is a **private** repo, so Actions minutes count against the free **2,000 minutes/month**.
The default schedule uses roughly **1,150–1,700 minutes/month** — a large share of that quota
— so think before making it more frequent. (Cloudflare Workers' free tier is generous and is
not the limiting factor here; GitHub Actions minutes are.)

To change it, edit the **`cron:`** line near the top of `.github/workflows/deploy.yml`:

```yaml
schedule:
  - cron: "0,30 13-23 * * 1-6"
```

- **Cost less:** change `0,30` to `0` (hourly, about half the minutes), or shorten the hour
  range (e.g. `14-22`), or use `1-5` for Monday–Friday only.
- **Cheapest useful:** `0 14 * * 1-5` runs once each weekday morning (~22 runs/month).
- **Cost more:** add minute marks, e.g. `0,15,30,45` (doubles the minutes).

The workflow file has a full comment block explaining this math right above the `cron` line.

---

## Troubleshooting

- **Actions run failed on "Reconstruct secrets.json":** one of `ST_CLIENT_ID`,
  `ST_CLIENT_SECRET`, `ST_APP_KEY`, or `ST_TENANT_ID` is missing/blank in repo secrets.
- **Actions run failed on "Deploy to Cloudflare Workers":** check `CLOUDFLARE_API_TOKEN`
  (correct token, "Edit Cloudflare Workers" permissions, not expired) and
  `CLOUDFLARE_ACCOUNT_ID` (matches your account). Re-copy from Step 3 if unsure.
- **The URL opens the dashboard with NO login prompt:** Cloudflare Access isn't enabled yet
  (or is misconfigured). Redo Step 7 — until Access is on, the URL is public.
- **An approved person can't get in / never gets a PIN:** confirm their exact email is in
  the Include → **Emails** list of the Access policy (Step 7b), and that the login method is
  **One-time PIN**.
- **`secrets.json` showed up on GitHub:** remove it immediately and rotate those ServiceTitan
  credentials — it should never appear (it's gitignored; you likely force-added it).
