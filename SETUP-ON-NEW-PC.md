# Setting up the Sierra Dashboard on a new Windows PC

This guide moves the dashboard onto another Windows computer (e.g., Troy's) so it runs
locally, the same way it runs now. **No coding needed.** Just follow the steps in order.

Plan on about **10 minutes**. You'll need:
- The `st-dashboard` folder (copied from the working computer — see Step 1).
- A working **internet connection** on the new PC (the dashboard pulls live data from ServiceTitan).
- The **4 ServiceTitan credential values** (see Step 3). Get these from the ServiceTitan
  app settings or from whoever set them up — but do **not** have them emailed in a file.

> **PREREQUISITE — who can get the credentials.** The 4 values live in ServiceTitan under
> **Settings → Integrations → API Application Access**. **A regular login cannot see that
> screen** — Oliver's own login could not reach it. You need **Troy's login or another admin
> login** to open it. So whoever sets this up must EITHER: (a) sign in with a login that can
> reach that screen and read the values there, OR (b) have the 4 values — **clientId,
> clientSecret, appKey, tenantId** — handed to them directly (in person / typed in on the PC),
> not emailed. Line this up before you start, or you'll be stuck at Step 3.

Nothing else needs to be downloaded or installed. Windows already includes everything required.

---

## Step 1 — Copy the folder over

1. Copy the **entire `st-dashboard` folder** to the new PC. A USB stick or OneDrive is fine.
2. Put it somewhere easy to find, like the **Desktop**. So you end up with:
   `C:\Users\<name>\Desktop\st-dashboard`
3. **IMPORTANT — do not copy the credentials file.** Open the copied folder and look for a
   file named **`secrets.json`**. **If it's there, delete it.** Credentials must be typed in
   fresh on the new machine (Step 3), never carried over in a file or sent by email.

> Everything else in the folder is safe to copy as-is. If you see a `data` folder, that's just
> saved past numbers — harmless to keep or delete.

---

## Step 2 — Check there's nothing to install

There isn't. The dashboard runs on **Windows PowerShell**, which is already built into Windows —
no Node, no Python, no downloads.

To confirm the PC is ready, just make sure it can reach the internet (open any website in a
browser). That's it. Move on to Step 3.

---

## Step 3 — Enter the ServiceTitan credentials safely

You'll create the `secrets.json` file **by typing it on this PC** (never paste from an email).

1. Open the `st-dashboard` folder.
2. Find the file **`secrets.example.json`**. Right-click it → **Copy**, then right-click empty
   space → **Paste**. You'll get a copy named `secrets.example - Copy.json`.
3. Rename that copy to exactly **`secrets.json`**:
   - Right-click it → **Rename** → type `secrets.json` → Enter.
   - If Windows warns about changing the file type, click **Yes**.
4. Right-click **`secrets.json`** → **Open with** → **Notepad**.
5. You'll see four lines with `xxxxx` placeholders. Replace each placeholder (the part inside
   the quotes) with the real value. It should end up looking like this, with real values:

   ```json
   {
     "clientId": "cid.abc123...",
     "clientSecret": "cs1.abc123...",
     "appKey": "ak1.abc123...",
     "tenantId": "1066404518"
   }
   ```

   - Keep all the quotes, colons, and commas exactly as they are — only change what's inside the quotes.
   - `tenantId` is **1066404518** (that one's not secret).
   - The other three come from ServiceTitan: **Settings → Integrations → API Application Access**,
     the "Sierra Claude Access" app. Type or paste them straight into Notepad here.
     **Reaching that screen needs Troy's login or an admin login** (see the PREREQUISITE at the top) —
     a regular login can't open it. If you don't have such a login, get the three values handed to
     you directly and type them in here.
6. **File → Save** (not "Save As"). Close Notepad.

> Safety notes: `secrets.json` stays only on this computer. Don't email it, don't put it in a
> shared drive, and don't paste the values into chat. If you ever need to move the dashboard
> again, re-enter the credentials fresh — don't copy this file.

**Double-check the file name.** It must be `secrets.json`, not `secrets.json.txt`. If you're
not sure: in the folder, click the **View** menu at the top and turn on **File name extensions**.
The file should read `secrets.json`. If it says `secrets.json.txt`, rename it to remove the `.txt`.

---

## Step 4 — Start it (one command)

1. Open the `st-dashboard` folder in File Explorer.
2. Click once in the **address bar** at the top (where the folder path is shown), type the word
   **`powershell`**, and press **Enter**. A blue PowerShell window opens, already pointed at the folder.
3. Copy this line, paste it into the PowerShell window (right-click pastes), and press **Enter**:

   ```
   powershell -ExecutionPolicy Bypass -File serve.ps1
   ```

4. You should see:

   ```
   Sierra dashboard server running.
   Open in your browser:  http://localhost:8787
   Press Ctrl+C to stop.
   ```

**Leave this window open.** Closing it stops the dashboard.

---

## Step 5 — Open it in the browser

1. Open a web browser (Chrome, Edge — any).
2. Go to this address:

   ```
   http://localhost:8787
   ```

3. The page loads right away. **The first time you open a given day or month, the numbers take
   a couple of minutes to appear** while it pulls fresh data — that's normal, not a freeze.
   After that it's fast, and it refreshes itself.

Tip: on the browser page, press **F11** for full-screen (press F11 again to exit) — good for a wall TV.

---

## Step 6 — Keeping it running on a wall display

For an always-on wall screen:

1. **Keep the PowerShell window from Step 4 open** and keep the browser tab open (F11 full-screen).
2. **Stop the computer from sleeping**, or the dashboard goes dark:
   - Click **Start**, type **`Power & sleep settings`**, press Enter.
   - Set **Screen** and **Sleep** both to **Never** (at least for "When plugged in").
3. Optional: turn off the screen saver the same way, so the numbers stay visible.

**What happens if the computer sleeps, restarts, or the window gets closed:**
- The dashboard **stops** (it's a program running in that PowerShell window).
- Nothing is broken and no data is lost. You just need to **start it again** — repeat Step 4,
  then refresh the browser (or reopen `http://localhost:8787`).

Optional "start automatically after a restart" (nice-to-have, not required): create a shortcut so
you don't have to retype the command.
- Right-click the Desktop → **New → Shortcut**.
- For the location, paste:
  ```
  powershell -ExecutionPolicy Bypass -File "C:\Users\<name>\Desktop\st-dashboard\serve.ps1"
  ```
  (replace `<name>` with the Windows user name — check the real path in File Explorer's address bar).
- Name it **Start Sierra Dashboard**. Double-clicking it now starts the dashboard.
- To have it run on login: press **Windows key + R**, type **`shell:startup`**, Enter, and drag a
  copy of that shortcut into the folder that opens. After a restart it launches on its own; then
  just open the browser to `http://localhost:8787`.

---

## Step 7 — Troubleshooting (the usual suspects)

**1. PowerShell says "running scripts is disabled on this system."**
You skipped the safety flag. Use the full command from Step 4 (it includes `-ExecutionPolicy Bypass`):
```
powershell -ExecutionPolicy Bypass -File serve.ps1
```

**2. The window flashes an error mentioning `secrets.json`, or the browser shows
"COULD NOT LOAD DATA."**
Almost always the credentials file. Check, in order:
- Is there a file named exactly **`secrets.json`** in the folder? (Not `secrets.json.txt` — see the
  file-name note at the end of Step 3. Not `secrets.example.json`.)
- Open it in Notepad and confirm all four values are filled in with no leftover `xxxxx`, and the
  quotes/commas are intact.
- Is the PC actually online? The dashboard needs internet to reach ServiceTitan.
Fix the file, save, then start it again (Step 4).

**3. The browser page won't open / says it can't connect to `localhost:8787`.**
- Make sure the **PowerShell window from Step 4 is still open** and shows "server running." If you
  closed it or the PC slept, just start it again (Step 4).
- Make sure you typed the address exactly: `http://localhost:8787`.
- If it still won't start and the window mentions "access is denied," right-click the PowerShell
  option and **Run as administrator**, then run the Step 4 command again.

**First-view slowness is not a bug.** A day or month you haven't opened before takes 1–2 minutes to
compute the first time (the SILO month can take ~2 minutes). It's cached after that and loads instantly.

---

**That's it.** Copy the folder, enter the credentials fresh, run the one command, open the browser.
If something's off, it's nearly always the `secrets.json` file name or the PowerShell window being
closed — both are quick fixes above.
