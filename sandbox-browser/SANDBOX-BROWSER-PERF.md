# sandbox-browser: interactive Firefox performance — handoff

Brief for an agent changing the `docker.io/anthonysautomations/sandbox-browser`
image (source is **not** in this repo). Goal: make the Firefox that a person uses
over RDP responsive on a 2-core, GPU-less node, **without** breaking
programmatic driving of the browser (Playwright launched from an SSH session).

Findings below come from pod `interwebz-d5886fd98-c7nfh` running image tag
`2026.11.08.1` on 2026-11-11. "Verified" = observed in the running container;
everything else is a recommendation to be measured.

## 1. Diagnosis (verified)

- Node `k3s-pw1` (2 vCPU, 1500m allocatable, 8 GB) at 100% CPU, load avg ~10.8,
  container CPU PSI `some avg60=95%`. Memory is fine (~2.3 GB used).
- CPU consumers, 5 s `top` sample, all Firefox:
  - `RDD Process` (media decoder) ~72%: a tab decoding video/animated media in software
  - parent `firefox` ~60%: software WebRender + compositing (no `/dev/dri`, no GPU)
  - one `Isolated Web Content` ~28%; 13 content processes total
  - Xvnc ~4%
- Network is **not** the bottleneck: HTTP via tinyproxy ~150 ms, proxy→origin
  TCP 40–60 ms, ping RTT 32 ms, DNS ~20 ms. HTTPS took 0.4–0.9 s only because
  TLS ran on a starved CPU.
- Playwright's automation prefs are **not** active in the RDP-launched browser:
  XFCE "Web Browser" → `exo-open` → helper `firefox` on `PATH` →
  `/usr/local/bin/firefox`, which sets `SANDBOX_BROWSER_INTERACTIVE=1`, and
  `playwright.cfg` wraps all its prefs in `if (!getenv("SANDBOX_BROWSER_INTERACTIVE"))`.
  So the interactive browser runs on stock Firefox defaults. That is the hook for
  the changes below. (Not checked in `about:config`; do that first, see §5.)

## 2. Current image layout (verified)

| Path | What |
|---|---|
| Base | Ubuntu 24.04, XFCE + xrdp + Xvnc (`:10`, 1280x1024, depth 16), sshd on 2222 |
| `/ms-playwright/firefox-1555/firefox/` | Playwright's patched Firefox 157.0 (Juggler) |
| `/ms-playwright/firefox-1555/firefox/playwright.cfg` | autoconfig; first line comment, line 2 `if (!getenv("SANDBOX_BROWSER_INTERACTIVE")) {` …automation prefs… `}` |
| `/ms-playwright/{chromium-1248,chromium_headless_shell-1248,webkit-2370,ffmpeg-1013}` | other Playwright browsers |
| `/opt/sandbox-browser/{firefox,chromium}` | symlinks into `/ms-playwright` |
| `/usr/local/bin/firefox` | `exec env SANDBOX_BROWSER_INTERACTIVE=1 /opt/sandbox-browser/firefox "$@"` |
| `/usr/local/bin/chromium` | adds `--no-sandbox` only when user namespaces are unavailable |
| `/opt/playwright/node_modules/playwright` | Playwright 1.64.1; env `NODE_PATH=/opt/playwright/node_modules`, `PLAYWRIGHT_BROWSERS_PATH=/ms-playwright` |
| `/usr/local/bin/{entrypoint,session-hook,readiness-probe,liveness-probe}.sh` | single-tenant session lifecycle; do not change semantics |
| Profile | `~/.config/mozilla/firefox/<rand>.default-default` (on an emptyDir `$HOME`, fresh per pod) |

Runtime constraints from `apps/interwebz/deployment.yaml` (this repo): Pod Security
`restricted`, UID/GID 10000, `readOnlyRootFilesystem`, all caps dropped,
writable only `$HOME`, `/tmp`, `/run/sandbox`, `/run/xrdp`, `/dev/shm` (1 GiB).
No direct Internet: egress only via `http://tinyproxy.tinyproxy.svc.cluster.local:8888`
(env `http(s)_proxy` set; the profile also has manual proxy prefs). Anything
fetched at runtime (e.g. extensions) goes through that proxy.

## 3. Hard constraint: programmatic driving must keep working

Baseline that must still pass after your change, run from an SSH session
(verified with `kubectl exec`: title "Example Domain", Firefox 157.0, ~10.5 s on the starved node):

```js
// node /tmp/pw-probe.js   (NODE_PATH already points at /opt/playwright/node_modules)
const { firefox } = require("playwright");
(async () => {
  const b = await firefox.launch({ headless: true, proxy: { server: process.env.https_proxy } });
  const p = await b.newPage();
  await p.goto("https://example.com");
  console.log(await p.title(), b.version());
  await b.close();
})().catch(e => { console.error(e); process.exit(1); });
```

Also keep a headed launch working from SSH while an RDP session is up
(`DISPLAY=:10 XAUTHORITY=$HOME/.Xauthority`, `headless: false`). This was not tested;
confirm it works before your change so a later failure isn't blamed on it.

Rules that follow:
- Playwright launches `/ms-playwright/firefox-1555/firefox/firefox` directly, without
  `SANDBOX_BROWSER_INTERACTIVE`. **Do not modify the automation branch of
  `playwright.cfg`**, the Juggler build, `PLAYWRIGHT_BROWSERS_PATH`, or `NODE_PATH`.
- Do not put interactive tweaks anywhere every launch reads: `distribution/policies.json`,
  `defaults/pref/*.js` in the Playwright Firefox dir, or a global `mozilla.cfg`.
  Automation would inherit them (extensions, autoplay blocking, and so on).
- Keep the Firefox version that `playwright@1.64.1` expects (`firefox-1555`). If
  you upgrade Playwright, upgrade the npm package and `/ms-playwright` together
  (`npx playwright install firefox`) and re-apply the cfg patch step.
- Keep `/usr/local/bin/firefox` as the desktop entry point (XFCE resolves it via PATH).

## 4. Changes to make (priority order)

### 4.1 Interactive-only prefs: `else` branch in `playwright.cfg` (do this first)
The Dockerfile already patches `playwright.cfg` to add the `if`. Extend that
step to close the `if` with an `else { … }` that runs only for the desktop
browser. Use `pref()` (defaults the user can still change), not `lockPref()`.
Candidates (verify names against Firefox 157 in `about:config` before relying on them):

```js
} else {
  // Media: the largest single CPU consumer observed.
  pref("media.autoplay.default", 5);                 // block audible + inaudible autoplay
  pref("media.autoplay.blocking_policy", 2);
  pref("media.av1.enabled", false);                  // AV1 software decode is the most expensive; sites fall back to VP9/H.264
  // Rendering: every frame is software-composited and re-encoded by Xvnc/xrdp.
  pref("layout.frame_rate", 30);
  pref("general.smoothScroll", false);
  pref("toolkit.cosmeticAnimations.enabled", false);
  pref("ui.prefersReducedMotion", 1);
  pref("image.animation_mode", "once");
  // Fewer content processes on 2 cores (Fission still isolates sites; measure).
  pref("dom.ipc.processCount", 4);
  pref("dom.ipc.processCount.webIsolated", 1);
  pref("browser.tabs.unloadOnLowMemory", true);
  // Less third-party junk = less CPU and fewer CONNECT tunnels via tinyproxy.
  pref("browser.contentblocking.category", "strict");
  pref("privacy.trackingprotection.enabled", true);
  pref("privacy.trackingprotection.socialtracking.enabled", true);
  // Background noise.
  pref("browser.sessionstore.interval", 60000);
  pref("browser.newtabpage.activity-stream.feeds.topsites", false);
  pref("browser.newtabpage.activity-stream.feeds.section.topstories", false);
  pref("extensions.pocket.enabled", false);
  pref("network.trr.mode", 5);                        // proxy resolves names; no DoH attempts
  // Interactive-only enterprise policies (see 4.2).
  pref("browser.policies.alternatePath", "/etc/sandbox-browser/firefox-policies.json");
}
```

### 4.2 Content blocker through interactive-only policies
Create `/etc/sandbox-browser/firefox-policies.json` (read-only, root-owned, which
is fine). Only the `else` branch points at it. Install uBlock Origin via
`ExtensionSettings` (`installation_mode: force_installed`,
`install_url: https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi`).
The download goes through tinyproxy at first start, which the filter allows (`.`).
Baking the `.xpi` into the image and using a `file://` install_url avoids the
fetch on every fresh pod; prefer that. You can also disable telemetry, studies
and first-run pages here (`DisableTelemetry`, `DisableFirefoxStudies`,
`OverrideFirstRunPage: ""`, `DontCheckDefaultBrowser`).

### 4.3 Desktop session overhead
- Disable xfwm4 compositing: ship
  `/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml` with `use_compositing=false`
  (it is copied into each fresh `$HOME` by the XFCE defaults mechanism).
- xrdp `max_bpp=32` while Xvnc runs depth 16. Set `max_bpp=16` in `xrdp.ini`
  to match (less conversion/encoding). Measure; optional.
- Disable the XFCE screensaver/power-manager/tumbler if installed (background CPU).

### 4.4 Only if 4.1–4.3 are not enough: separate stock Firefox for the desktop
Install Mozilla's Firefox ESR tarball at `/opt/firefox-esr` (not the Ubuntu snap
stub). Point `/usr/local/bin/firefox` at it with a `defaults/pref` + policies file
of its own. Leave `/ms-playwright/firefox-1555` untouched for automation. Cost:
roughly +100 MB image size and a second browser to keep updated. Benefit: a
release-channel browser with no Juggler patches. Note: the Playwright build is
Firefox 157 (Nightly-era patches), so ESR is older.

### 4.5 Session end after an RDP disconnect (bug, verified 2026-11-11)
Disconnecting RDP did not end the session, so the pod stayed claimed indefinitely:
- `sesman.ini` has `KillDisconnected=false`. The image relies on `[Xvnc] param=-MaxDisconnectionTime=10`.
  Xvnc logged `MaxDisconnectionTime reached, exiting` 10s after the disconnect but kept running.
  TigerVNC's exit is `kill(getpid(), SIGTERM)`.
- **No process in any container on this cluster can deliver a signal**, not even to its own
  child (`sleep 30 & kill $!` → EPERM; `kill -0` succeeds). Verified in interwebz, ns0 and tinyproxy.
  All run under the AppArmor label `cri-containerd.apparmor.d//&unconfined` (Ubuntu 26.04,
  kernel 7.0). Signals from outside (kubelet/runc) still work: pod deletion exited cleanly in 2s.
  The suspected cause is containerd's default profile matching signal peers by the unstacked
  label; this is node-level and not confirmed from the host.
- Consequences inside the image: Xvnc self-exit, sesman's SIGTERM to Xvnc/chansrv, and
  `entrypoint.sh` `cleanup()`'s `kill "$pid"` all fail silently.
  PID 1 exiting is still clean, because the kernel tears down the PID namespace.
- k8s-side mitigation (this repo): the liveness probe fails when every session marker belongs
  to `xrdp-sesman` and no TCP connection is ESTABLISHED on port 3389. The kubelet then restarts
  the container after about 30-45s.
- Image-side fix (preferred, and it must not depend on signals): in the `entrypoint.sh` main loop,
  treat an `xrdp-sesman` marker as ended once nothing has been connected on :3389 for N seconds
  (keep a timestamp), then `exit 0`. Also set `KillDisconnected=true` / `DisconnectedTimeLimit`
  in case signals are fixed on the nodes later. Afterwards the probe override in
  `apps/interwebz/deployment.yaml` can return to `/usr/local/bin/liveness-probe.sh`.

## 5. Verification (acceptance criteria)

1. Build with a new date tag (current pattern `YYYY.MM.DD.N`), push, then bump
   `image:` in `apps/interwebz/deployment.yaml` in this repo (the `k8s-infra`
   repo; Argo CD syncs `clusters/k3s-yyz/apps/interwebz.yaml`).
2. Interactive browser (RDP → Web Browser), in `about:config`: `media.autoplay.default`=5,
   `browser.policies.alternatePath` = the interactive file, uBlock present.
   `dom.iframe_lazy_loading.enabled` should be `true` (proves the automation branch is skipped).
3. Automation browser: the §3 probe passes headless and headed. Also inside a Playwright
   page, the interactive tweaks must be absent: no uBlock, autoplay allowed. Check with
   `await p.evaluate(() => { const v = document.createElement('video'); v.muted = true; return navigator.getAutoplayPolicy?.('mediaelement'); })`
   (expect `"allowed"`) or by observing extension absence.
4. Load: with the RDP browser on a news site plus one video page, sample
   `cat /proc/pressure/cpu` and `top -bn2 -d5` in the pod. Before the change
   (the baseline above), PSI some avg60 was ~95% and RDD ~72%. Report the after numbers.
5. Cold page load timing from the pod: `curl -s -o /dev/null -w '%{time_appconnect} %{time_total}\n' https://example.com`.
   Expect well under the 0.4–0.9 s seen while starved.

## 6. Already done on the k8s side (this repo, not the image)

- tinyproxy: `dnsConfig` `ndots:1` (cold external lookups no longer walk 4 search domains).
- interwebz: liveness also fails on an RDP session with no RDP client (see 4.5);
  readiness probe 2s→5s, liveness 5s→15s, CPU request 500m→900m,
  strategy `Recreate`. On the only node with enough RAM (`k3s-pw1`), the old and
  new pods would not both fit at that request.
