# Install-Striim.ps1 — Striim for Windows Setup & Maintenance Wizard

`Install-Striim.ps1` is a guided installer for **Striim 5.x+** on Windows. It installs, verifies, repairs, reconfigures, upgrades, and uninstalls the **Striim Forwarding Agent** (its primary use case) or a **Striim Node**, handling every prerequisite — Java 17, the Visual C++ runtime, the Microsoft OLE DB driver, JDBC drivers, the Windows service, and keystore setup — in one pass.

You answer all questions up front, review a plan card showing exactly what will happen, approve **one** UAC elevation prompt, and the rest runs unattended. A full transcript is written for every run.

> **Striim 4.x?** This wizard supports Striim 5.x and later only (the Java 17 line). For 4.x installs, use the legacy `msjetchecker.ps1` instead.

---

## Contents

1. [Requirements](#requirements)
2. [Quick start](#quick-start)
3. [How an install works](#how-an-install-works)
4. [The interview, question by question](#the-interview-question-by-question)
5. [What gets installed](#what-gets-installed)
6. [Network requirements](#network-requirements)
7. [Command-line parameters](#command-line-parameters)
8. [Offline / air-gapped installs](#offline--air-gapped-installs)
9. [Maintenance menu (existing installs)](#maintenance-menu-existing-installs)
10. [Uninstalling](#uninstalling)
11. [Logs and transcripts](#logs-and-transcripts)
12. [Troubleshooting](#troubleshooting)
13. [Security notes](#security-notes)
14. [FAQ](#faq)

---

## Requirements

| Requirement | Detail |
|---|---|
| Operating system | 64-bit Windows (Windows Server 2016+ or Windows 10 1809+ recommended). 32-bit systems are rejected. |
| PowerShell | Windows PowerShell 5.1 (the Server 2016+ default) or PowerShell 7. No modules needed. |
| Account | Any user account to answer the interview. **One** UAC admin approval is required to execute the plan. |
| Disk | 500 MB minimum for an Agent; the install drive should never drop below 10% free. 15 GB free is recommended for a Node. |
| Memory | 256 MB – 1 GB for the agent itself, depending on the adapters in use. |
| CPU | Plan roughly one core per two MSJet instances. |
| Network | Outbound HTTPS to download Striim and prerequisites (or use [offline mode](#offline--air-gapped-installs)), plus [connectivity to your Striim cluster](#network-requirements). |

Every run opens with the wizard banner:

```
==========================================================================
            STRIIM  -  Install-Striim.ps1  Setup & Maintenance Wizard
==========================================================================
```

For a fresh install, the interview then prints a system snapshot (OS, PowerShell version, cores, RAM) plus the requirement reference numbers, so you can sanity-check the machine before answering anything:

```
--- System snapshot ---
  OS:          Microsoft Windows Server 2019 Standard
  PowerShell:  5.1.17763.6414
  CPU cores:   8
  RAM:         16 GB

--- Striim agent requirements (for reference) ---
  Disk: 500 MB minimum; never let the drive drop below 10% free.
  RAM:  256 MB - 1 GB depending on adapters in use.
  CPU:  plan +1 core per 2 MSJet instances (N cores ~ 2N MSJet sources).
```

If the machine has less than 1 GB RAM you get a warning here but can continue.

---

## Quick start

From any PowerShell window (no admin needed yet):

```powershell
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/striim/windows-installer/main/Install-Striim.ps1" -OutFile "Install-Striim.ps1"
Unblock-File -Path "Install-Striim.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Striim.ps1
```

That's it. The wizard takes over:

- **Fresh machine** → interview → plan review → one UAC prompt → unattended install → verification report.
- **Machine with an existing Striim install** → [maintenance menu](#maintenance-menu-existing-installs) (verify / add drivers / update settings / manage service / reinstall / upgrade / uninstall / new install).

> **Tip:** run the script from the directory where you want the `downloads\` cache to live. Downloaded files are cached and reused on every subsequent run, so retries and reinstalls never re-download what's already present.

---

## How an install works

On a machine with no existing install, the wizard runs six phases:

```
Detect  →  Interview  →  Plan review  →  One UAC prompt  →  Execute  →  Verify
```

### 1. Detect

Looks for existing Striim installs three ways: registered Windows services (`Striim Agent` / `Striim`), well-known paths on every fixed drive (e.g. `C:\striim\Agent`), and a shallow one-level scan of each drive root for `*striim*` folders. If anything is found you get the maintenance menu instead of a fresh install. If nothing is found you'll see:

```
[INFO   ] No existing Striim installation detected - starting the install interview.
```

### 2. Interview

Every decision is collected **once, up front**, with immediate validation (see [the interview](#the-interview-question-by-question)). Nothing requires admin rights yet, and nothing is changed on the machine.

### 3. Plan review

A numbered card lists exactly what will happen. Prerequisites that are already present are listed as "present" / "verify only" — **only missing things get install actions**. Warnings (e.g. the cluster was unreachable during the interview) appear on the card. Approving this card is the only consent the wizard asks for; there are no further per-file or per-step prompts.

```
+------------------------------------------------------------------------
| INSTALL PLAN - Striim Forwarding Agent 5.4.0.6 -> D:\striim\Agent
|  1. Download Striim_Agent_5.4.0.6.zip  (cached: no)
|  2. Download + silently install Microsoft Build of OpenJDK 17  (missing)
|  3. Install Visual C++ 2015-2019 Redistributable x64 14.29 (MSJet requires the 2015-2019 line)  (missing)
|  4. Install Microsoft OLE DB Driver for SQL Server  (missing)
|  5. Extract Forwarding Agent -> D:\striim\Agent
|  6. Add D:\striim\Agent\lib to the system PATH
|  7. Write conf\agent.conf (cluster=MyCluster, server=striim01.example.com, HTTPS)
|  8. Install JDBC drivers: MariaDB (v2.4.3), PostgreSQL (v42.2.27)
|  9. Register 'Striim Agent' Windows service
| 10. Generate keystore via aksConfig.bat  (passwords provided)
| Warning: cluster auth port 9081 on striim01.example.com was unreachable from this host
+------------------------------------------------------------------------
Proceed? (approval covers all listed downloads and installs) (Y/n):
```

Pressing Enter (or `y`) proceeds; `n` stops with nothing changed:

```
[INFO   ] Stopped at plan review. Nothing was changed.
```

### 4. One UAC prompt

The wizard relaunches itself elevated:

```
[INFO   ] One UAC prompt follows - the elevated process executes the whole plan unattended.
```

Your interview answers ride along in a plan file (`install-plan.json`) whose passwords are DPAPI-encrypted (readable only by your own Windows account on this machine); the file is deleted automatically when execution finishes.

### 5. Execute

Numbered steps run unattended. Each step first checks whether its goal is already met before acting, so re-running after a failure is always safe:

```
[STEP   ] [1/10] Download required files (4 item(s))
[INFO   ] Downloading Striim_Agent_5.4.0.6.zip via curl.exe...
[SUCCESS]   Done.
[STEP   ] [2/10] Java 17 (Microsoft Build of OpenJDK)
[SUCCESS]   Already present - nothing to do.
```

If a step fails you get a pause menu:

```
[ERROR  ] Step failed: Microsoft OLE DB Driver for SQL Server
[INFO   ] Full log: D:\striim\Agent\logs\install-20260616-101500.log
[R]etry / [S]kip / [A]bort:
```

Critical steps (downloads, Java 17, extraction, configuration, deregistering/removing during upgrade or uninstall) cannot be skipped:

```
[R]etry / [A]bort (critical step - cannot skip):
```

### 6. Verify

Every requirement is re-checked and reported as a summary card, followed by a "next steps" section. The elevated window stays open until you press Enter so you can read the result:

```
==========================================================================
 INSTALL SUMMARY
==========================================================================
 [DONE] Download required files (4 item(s))
 [OK]   Java 17 (Microsoft Build of OpenJDK)
 [DONE] Visual C++ 2015-2019 Redistributable (x64)
 [DONE] Microsoft OLE DB Driver for SQL Server
 [DONE] Extract Striim -> D:\striim\Agent
 [DONE] Copy installer script into the install directory
 [DONE] Add D:\striim\Agent\lib to the system PATH
 [DONE] Write conf\agent.conf
 [DONE] Install JDBC driver: MariaDB (v2.4.3)
 [DONE] Register 'Striim Agent' Windows service
 [DONE] Generate keystore via aksConfig.bat

 Verification:
 [PASS] Windows service 'Striim Agent' registered
 [PASS] Java 17 resolvable (PATH and JAVA_HOME)
 [PASS] Required config props non-empty in conf\agent.conf
 [FAIL] Cluster auth port 9081 reachable
 [PASS] Install drive has >= 10% free disk

 Warnings:
  - cluster auth port 9081 on striim01.example.com was unreachable from this host

 Transcript (send this file to Striim support if anything failed):
   D:\striim\Agent\logs\install-20260616-101500.log

 Next steps:
   Start the service:   Start-Service 'Striim Agent'
   Stop the service:    Stop-Service 'Striim Agent'
   Agent logs:          D:\striim\Agent\logs\
   In the Striim console: once started, the agent appears under Monitor > Agents for cluster 'MyCluster'.
   Install transcript:  D:\striim\Agent\logs\install-20260616-101500.log

Press Enter to close this window:
```

The summary tags are: `[DONE]` (a missing item was just installed), `[OK]` (already present, nothing to do), `[PASS]`/`[FAIL]` (a verify check), and `[SKIP]` (a non-critical step you skipped).

If you skipped the keystore passwords in the interview, the keystore configuration step runs **last** and prompts you interactively — everything before it is hands-off:

```
[INFO   ] One final step needs your input: keystore configuration.
```

---

## The interview, question by question

The interview is collected in the exact order below. Where a value can be prefilled (from a restored backup or a live config), the default is shown in `[brackets]` and Enter accepts it.

| Question | What you see / Notes |
|---|---|
| **Install profile** | A pick list — `1` selects the Agent (default), `2` selects a Node. |
| **Striim version** | Defaults to `5.4.0.6`. The wizard immediately checks the release server for that version, so a typo fails in about a second instead of after a long download. Versions below 5.0 are rejected; early 5.0.x builds (before ~5.0.6, the Java 11 era) get a warning and a confirmation. |
| **Install path** | A free-space table of all fixed drives is shown. Enter a drive letter (e.g. `D`) for the standard layout, or type a full path. The 500 MB / 10%-free checks run against the drive you actually picked. |
| **Restore a prior config backup?** *(only when backups exist)* | If `<drive>:\striim_backups\` holds backups, a pick list shows them newest-first with what each contains. The chosen backup's cluster settings become press-Enter defaults; its keystore pair and non-default JDBC jars are copied back automatically after extraction. |
| **Cluster name / Server address / HTTPS** | The Striim cluster this agent joins, a server node hostname/IP, and whether HTTPS is enabled (auth port `9081` for HTTPS, `9080` for HTTP). The wizard probes the address/port immediately and warns **now** if it's unreachable. |
| **License details** *(Node only)* | `CompanyName`, `LicenceKey`, and `ProductKey` — required for a Node, never asked for an Agent. |
| **MEM_MAX** | Optional JVM max-heap value (e.g. `2048m`). Press Enter to skip. |
| **SQL Server Integrated Security?** | If yes, `sqljdbc_auth.dll` is placed in `C:\Windows\System32` for NT (Windows) authentication to SQL Server. Default is no. |
| **JDBC drivers** *(Agent only)* | A multi-select checklist (e.g. `1,4`, `all`, or Enter for none). Manual-path drivers prompt for a vendor jar/dir, validated immediately. |
| **Windows service?** | Registers `Striim Agent` (or `Striim` for a Node) as a Windows service. Default is yes. |
| **Keystore + sys passwords** | Optional. Provide both and keystore generation is fully automatic; skip either and the keystore script runs interactively as the final step. Input is masked, and passwords are never written to disk in plaintext. |

### Picking the install profile

```
Install profile:
  [1] Striim Forwarding Agent (default)
  [2] Striim Node
Select 1-2:
```

### Choosing the Striim version

```
Striim version to install [5.4.0.6]:
[INFO   ] Validating release URL: https://striim-downloads.striim.com/Releases/5.4.0.6/Striim_Agent_5.4.0.6.zip
[SUCCESS] Version 5.4.0.6 confirmed on the release server.
```

If the release server can't confirm the version (typo, unreleased build, offline, or proxy):

```
[WARN   ] Could not confirm 5.4.0.6 on the release server (typo, unreleased version, or no internet).
Use this version anyway (e.g. offline with a pre-staged downloads\ bundle)? (y/N):
```

### Choosing the install path

A free-space table is shown first:

```
Drive         Free      Total   Note
C:         42.7 GB    127.0 GB   (system)
D:        612.3 GB    931.5 GB

Install path [C:\striim\Agent]  (pick a letter, e.g. 'D', or type a full path):
```

A bare letter expands to the standard layout (`D:\striim\Agent` for an Agent, `D:\striim` for a Node). Drives under 500 MB or 10% free trigger a confirm prompt; a Node on a drive with under 15 GB free gets an advisory (non-blocking) warning.

### Restoring a prior backup (only shown when backups exist)

```
Prior Striim config backups found under striim_backups\ - restore settings from one?
  [1] uninstall_5.4.0.6_20260601-093000  (config + keystore + 2 extra jar(s))  Backed up from D:\striim\Agent on 2026-06-01 09:30:00
  [2] reinstall_5.3.0.5_20260415-140000  (config)  Backed up from D:\striim\Agent on 2026-04-15 14:00:00
  [3] (none - answer everything fresh)
Select 1-3:
```

The keystore is only restored when the cluster name still matches the backup's. If you change the cluster name, the wizard warns and generates a fresh keystore instead:

```
[WARN   ] Cluster name differs from the backup's ('OldCluster') - the backed-up keystore belongs to that cluster and will NOT be restored; a new one will be generated.
```

### Cluster connection settings

```
Cluster name: MyCluster
Striim server node address (hostname or IP): striim01.example.com
Is HTTPS enabled on the cluster? (Y/n): y
[SUCCESS] Cluster auth port 9081 on striim01.example.com is reachable.
```

If the probe fails you can still continue:

```
[WARN   ] Cannot reach striim01.example.com on auth port 9081 from this host right now. Fix your firewall/VPN - you can continue anyway. (FYI for your network team: the agent also needs inbound TCP 5701 (Hazelcast) and outbound TCP 49152-65535.)
```

The server address may be a comma-separated list for HA clusters; the probe passes when **any** listed address answers.

### JDBC drivers (Agent only)

```
JDBC drivers to install into lib\:
  [1] MariaDB (v2.4.3)
  [2] MySQL / MemSQL (Connector/J 8.0.30)
  [3] Oracle Instant Client (for OJet)
  [4] PostgreSQL (v42.2.27)
  [5] HP NonStop (manual path to t4sqlmx.jar)
  [6] Teradata (manual dir with terajdbc4.jar + tdgssconfig.jar)
  [7] Vertica (manual path to vertica-jdbc-*.jar)
Select drivers (e.g. '1,4'), 'all', or Enter for none:
```

Options 1–4 are auto-downloaded. Options 5–7 require a vendor jar you supply; the wizard prompts for the path and validates it at interview time:

```
[Teradata (manual dir with terajdbc4.jar + tdgssconfig.jar)] Enter the directory containing terajdbc4.jar + tdgssconfig.jar (or 'skip'):
```

### Service and keystore

```
Register Striim as a Windows service? (Y/n): y

Keystore setup (optional - skip either to do keystore config interactively at the end):
Agent keystore password (press Enter to skip)
Cluster 'sys' user password (press Enter to skip)
```

Password input is masked. Provide both to make keystore generation automatic; leave either blank to run `aksConfig.bat` / `sksConfig.bat` interactively as the last step.

---

## What gets installed

Only the items that are **missing** are installed — anything already present is verified and left alone.

| Component | Detail |
|---|---|
| Striim Agent / Node | Official release zip, extracted to your chosen install path (the single top-level wrapper folder is flattened). |
| Java 17 | Microsoft Build of OpenJDK 17 (MSI, silent, `ADDLOCAL=FeatureMain,FeatureEnvironment,FeatureJavaHome`). Sets machine-wide `PATH` and `JAVA_HOME`. Existing Java installs are detected via PATH, `JAVA_HOME`, and the registry; if another Java would win on PATH, the wizard tells you exactly which one and how to fix it. |
| Visual C++ 2015–2019 Redistributable (x64), 14.28.29914+ | Detected via the registry (fast, no side effects). MSJet's native DLLs expect the 2015–2019 runtime line; if a 2015–2022 (14.30+) runtime is already installed the wizard warns and continues (the 14.x runtime upgrades in place, so 2015–2019 can't be installed alongside it). |
| Microsoft OLE DB Driver for SQL Server | Required for MSJet (installed silently with `IACCEPTMSOLEDBSQLLICENSETERMS=YES`). Already-installed versions outside the known-good list (`18.2.3.0`, `18.7.4.0`) produce a warning, not a block. |
| `sqljdbc_auth.dll` | → `C:\Windows\System32` (only if you chose Integrated Security). Copied from Striim's own `lib\` after extraction (with the script dir and `downloads\` as fallbacks) — nothing is downloaded. |
| System PATH | `<install>\lib` is appended to the machine PATH (deduplicated; removed again on uninstall). |
| Configuration | `conf\agent.conf` (Agent: cluster name, server address, HTTPS flag) or `conf\startUp.properties` (Node: company/license/product keys, cluster name), plus `MEM_MAX`/`MEM_MIN` if provided. Existing files are edited in place — properties are set or uncommented, never duplicated. The matching service `wrapper.conf` JVM args are kept in lockstep (see [Update Striim settings](#maintenance-menu-existing-installs)). |
| JDBC drivers | Selected jars → `<install>\lib\`. Oracle Instant Client is extracted to `<install>\oracle_instant_client` and wired up via `NATIVE_LIBS` in `agent.conf`. |
| Windows service | `Striim Agent` / `Striim`, registered via the official Striim service-wrapper package (yajsw) for your exact version. |
| Keystore | Generated via Striim's `aksConfig.bat` (Agent) / `sksConfig.bat` (Node). |
| The installer itself | A copy of `Install-Striim.ps1` is placed in the install directory so future maintenance runs can be launched right from there. |

All downloads are fetched with `curl.exe` (resume + automatic retries), falling back to BITS and then a direct HTTPS stream on systems without curl. Interrupted downloads land in `<name>.partial` and resume where they left off.

---

## Network requirements

Give this list to your network/firewall team:

| Direction | Port | Purpose |
|---|---|---|
| Outbound (agent → Striim server) | TCP `9081` (HTTPS) or `9080` (HTTP) | Cluster authentication |
| Inbound (Striim server → agent) | TCP `5701` | Hazelcast cluster communication |
| Outbound (agent → Striim server) | TCP `49152–65535` | Ephemeral data ports |
| Outbound (install time only) | TCP `443` | Downloads: `striim-downloads.striim.com`, `aka.ms`, `go.microsoft.com`, `repo1.maven.org`, `cdn.mysql.com`, `download.oracle.com`, `jdbc.postgresql.org` |

The wizard probes the cluster auth port during the interview **and** again during final verification, so a firewall problem is surfaced immediately rather than as a mysteriously absent agent.

---

## Command-line parameters

Running with no parameters starts the normal wizard. Parameters exist for the offline workflow and for the wizard's own internals:

| Parameter | Purpose |
|---|---|
| `-DownloadOnly` | Download everything into `downloads\` and exit — no install. Requires `-Version` and exactly one of `-Agent` / `-Node`. |
| `-Agent` | With `-DownloadOnly`: bundle Forwarding Agent files. |
| `-Node` | With `-DownloadOnly`: bundle Node files. |
| `-Version <x.y.z.b>` | Target Striim version (e.g. `5.4.0.6`). Used by `-DownloadOnly`; otherwise it's the interview default. |
| `-PlanFile <path>` | Internal — used by the wizard's own elevated relaunch. You never pass this yourself. |
| `-NoRun` | Internal — loads functions without executing anything (used by the test suite). |

---

## Offline / air-gapped installs

**On an internet-connected machine**, bundle everything:

```powershell
.\Install-Striim.ps1 -DownloadOnly -Agent -Version 5.4.0.6    # Forwarding Agent bundle
.\Install-Striim.ps1 -DownloadOnly -Node  -Version 5.4.0.6    # Node bundle
```

This fills `downloads\` and writes `downloads\manifest.json` — a file list with sizes and SHA-256 hashes so the receiving side can validate the bundle. You'll see a per-file log and a summary:

```
[SUCCESS] Bundle complete: 6 file(s) in C:\stage\downloads; manifest at C:\stage\downloads\manifest.json.
[INFO   ] Copy this whole directory (script + downloads\) to the offline machine and run the script normally.
```

If any download fails, re-run the same command; completed files are kept and partial files resume.

**On the offline machine**, copy the whole directory (the script plus `downloads\`) and run the script normally:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Striim.ps1
```

Cached files are used without any network access. When the interview can't reach the release server to confirm your version, answer **yes** to "Use this version anyway" — the pre-staged bundle covers it.

---

## Maintenance menu (existing installs)

Re-running the script on a machine that already has Striim opens the maintenance menu instead of the install interview. If several installs exist (e.g. an Agent and a Node), you pick one first:

```
Multiple Striim installs found - pick one:
  [1] D:\striim\Agent  (Agent, 5.4.0.6, service: Running)
  [2] C:\striim  (Node, 5.4.0.6, service: Stopped)
Select 1-2:
```

The menu itself, with a live header line showing the detected profile, version, path, and service state:

```
Existing Striim Agent 5.4.0.6 at D:\striim\Agent (service: Running)
  [1] Verify install health
  [2] Add/refresh JDBC drivers
  [3] Update Striim settings
  [4] Manage service
  [5] Clean reinstall
  [6] Upgrade version
  [7] Uninstall
  [8] New install (full interview - another path, or over this install)
  [0] Exit
Select:
```

| Option | What it does |
|---|---|
| **1 — Verify install health** | Runs every requirement check (service, Java 17, config, cluster reachability, disk space) and prints the report card. **Changes nothing** — safe to run any time, no admin needed. |
| **2 — Add/refresh JDBC drivers** | The same multi-select driver checklist as the install interview, then a mini-plan, one UAC prompt, driver placement, and a service restart so the new jars are picked up. Selecting nothing exits with `No drivers selected.` |
| **3 — Update Striim settings** | Re-asks the cluster settings, server address, HTTPS, and JVM heap, then rewrites **both** `agent.conf` **and** the service `wrapper.conf`, and restarts the service. See [Conflict-aware settings update](#conflict-aware-settings-update-option-3) below. |
| **4 — Manage service** | Shows the live service status, the account it runs under, and its PID, then lets you **Start**, **Stop**, or **Restart** the service from inside the wizard. See [Manage service](#manage-service-option-4) below. |
| **5 — Clean reinstall** | First offers the same config backup as uninstall (default **yes**, to `<drive>:\striim_backups\reinstall_<version>_<timestamp>\`), then clears the install directory — **always preserving** `downloads\`, `logs\`, and the installer scripts — and runs the full interview and install again. |
| **6 — Upgrade version** | The official upgrade procedure as one plan. Settings are read from the live config **before anything is touched**; the wizard then backs everything up to `<drive>:\striim_backups\upgrade_<oldversion>_<timestamp>\` (mandatory), stops and deregisters the old service (the wrapper is version-specific), cleans the directory, installs the new version, restores your keystore and non-default JDBC jars, and re-registers the service. See [Upgrade](#upgrade-version-option-6) below. |
| **7 — Uninstall** | Full removal — see [Uninstalling](#uninstalling). |
| **8 — New install** | Runs the full install interview even though an install was detected — for a second copy on another path, the other profile, or rebuilding a broken install. If the path you pick is the detected install's own path, the wizard switches to a clean-reinstall plan automatically (with the backup offer). |

All write actions go through the same plan card and single-UAC handoff as a fresh install, ending with `Proceed?`:

```
[SUCCESS] Cluster auth port 9081 on striim01.example.com is reachable.

+------------------------------------------------------------------------
| DRIVERS PLAN - Striim Forwarding Agent 5.4.0.6 -> D:\striim\Agent
|  1. Install JDBC drivers: PostgreSQL (v42.2.27)
|  2. Restart 'Striim Agent' service if registered
+------------------------------------------------------------------------
Proceed? (Y/n):
```

### Conflict-aware settings update (option 3)

The service wrapper bakes JVM args into `wrapper.conf` at install time and otherwise silently overrides `agent.conf` at startup. Option 3 surfaces where the two files disagree, defaults each prompt to the `agent.conf` value, and pressing Enter resolves the conflict by syncing both files:

```
--- Connection settings ---
Cluster name [MyCluster]:
Striim server node address (hostname or IP) [striim01.example.com]:
Is HTTPS enabled on the cluster? (Y/n):

--- JVM / Memory ---
  agent.conf:   2048m
  wrapper.conf: 4096m  <- conflict
Max heap (MEM_MAX) [2048m]:
```

`MEM_MIN` is only prompted for when it conflicts. If you enter a `MEM_MIN` larger than `MEM_MAX`, the wizard refuses to write a JVM-crashing config and re-asks:

```
[WARN   ] MEM_MIN (4096m) must be <= MEM_MAX (2048m). Re-enter both.
```

Use this when the agent points at the wrong cluster, the server address changed, or heap/cluster settings aren't taking effect.

### Manage service (option 4)

```
--- Service: Striim Agent ---
  Status:  Running
  Account: LocalSystem
  PID:     12345

  [1] Start
  [2] Stop
  [3] Restart
  [0] Back
Select:
```

Each action takes one UAC prompt and rides the same plan engine. No-ops (starting an already-running service, etc.) and transitional states (`Start Pending`, `Stop Pending`, …) are caught before any prompt. Stop force-kills a hung yajsw wrapper `java.exe` process after a 30 s timeout.

### Upgrade version (option 6)

```
Installed version: 5.4.0.6. Enter the version to upgrade to.
Striim version to install [5.4.0.6]: 5.5.0.1
```

If the target isn't newer than the installed version, you're warned and asked to confirm. The agent keeps its cluster identity — no keystore re-enrollment, no retyped settings — because the keystore and non-default jars are restored from the mandatory pre-upgrade backup.

---

## Uninstalling

Choose **[7] Uninstall** from the maintenance menu. Before anything happens, you answer three questions (all unelevated):

```
Back up conf\agent.conf, the keystore pair, and non-default lib\ jars to C:\striim_backups\uninstall_5.4.0.6_20260616-101500 first? (Y/n): y
Keep the downloads\ cache (useful for a future reinstall; it will move next to the backup dir)? (Y/n): y
Also remove sqljdbc_auth.dll from System32? Other SQL tooling on this box may use it. (y/N): n
```

1. **Back up first?** (default **yes**) — copies your config file, the keystore pair, and any non-default JDBC jars to `<drive>:\striim_backups\uninstall_<version>_<timestamp>\`, with a `backup-manifest.txt` listing what was saved. Any backup in `striim_backups\` is offered for restore the next time you run an install on the machine.
2. **Keep the `downloads\` cache?** (default **yes**) — moves it next to the backup folder for a future reinstall.
3. **Also remove `sqljdbc_auth.dll` from System32?** (default **no**) — other SQL tooling on the machine may use it.

You then see a **scope card** stating exactly what will be removed and what will be kept, and the final confirmation **defaults to No** — pressing Enter cancels with nothing changed:

```
+------------------------------------------------------------------------
| UNINSTALL PLAN - Striim Forwarding Agent 5.4.0.6 at D:\striim\Agent
| Will REMOVE:
|   - Windows service 'Striim Agent' (stopped, then deregistered)
|   - D:\striim\Agent (entire directory)
|   - D:\striim\Agent\lib entry on the machine PATH
| Will KEEP:
|   - Backup of config, keystore, and non-default jars -> C:\striim_backups\uninstall_5.4.0.6_20260616-101500
|   - downloads\ cache -> C:\striim_backups\uninstall_5.4.0.6_20260616-101500_downloads
|   - C:\Windows\System32\sqljdbc_auth.dll (other SQL tooling may use it)
|   - Shared components: Java 17, VC++ redistributable, MS OLE DB driver (manual removal hints in the summary)
+------------------------------------------------------------------------
Remove this Striim Forwarding Agent and its Windows service? (y/N):
```

Cancelling prints `Uninstall cancelled. Nothing was changed.`

What removal does, in order: backup → stop the service (force-killing the wrapper process if it hangs past 30 s) → deregister the service (via the bundled `uninstallService.bat`, falling back to `sc.exe delete`) → delete the install directory → remove the `lib` entry from the machine PATH → (optionally) remove `sqljdbc_auth.dll`.

After removal, the summary lists what was kept and the one-line manual removal hints for the shared components:

```
 Kept on this machine:
  Backup:    C:\striim_backups\uninstall_5.4.0.6_20260616-101500
  Downloads: C:\striim_backups\uninstall_5.4.0.6_20260616-101500_downloads

 Shared components deliberately left in place (other software may depend on them):
  - Java 17 (Microsoft Build of OpenJDK): Settings > Apps > "Microsoft Build of OpenJDK 17" > Uninstall
  - Visual C++ 2015-2019 Redistributable (x64): Settings > Apps > "Microsoft Visual C++ 2015-2019 Redistributable (x64)" > Uninstall
  - Microsoft OLE DB Driver for SQL Server: Settings > Apps > "Microsoft OLE DB Driver for SQL Server" > Uninstall

 Uninstall transcript: C:\striim_backups\uninstall-20260616-101500.log
```

The uninstall transcript is written to `<drive>:\striim_backups\uninstall-<timestamp>.log` (the install directory's `logs\` folder is itself being removed, so the transcript lives beside the backup).

---

## Logs and transcripts

| File | What it is |
|---|---|
| `<install>\logs\install-YYYYMMDD-HHmmss.log` | Complete transcript of every install/maintenance execution: each step, each command, each warning. **Attach this file when contacting Striim support.** Passwords are never written to it. |
| `<drive>:\striim_backups\uninstall-YYYYMMDD-HHmmss.log` | The uninstall transcript. |
| `<install>\logs\` | The agent's own runtime logs once it's started. |
| `downloads\manifest.json` | File list + SHA-256 hashes for an offline bundle. |
| `<drive>:\striim_backups\<flow>_<version>_<timestamp>\backup-manifest.txt` | Lists everything saved in a config backup. |

The transcript path is printed in the summary card at the end of every run, and again on any failure.

---

## Troubleshooting

### Script won't start

| Symptom | Fix |
|---|---|
| *"running scripts is disabled on this system"* | Launch exactly as shown in [Quick start](#quick-start): `powershell -NoProfile -ExecutionPolicy Bypass -File .\Install-Striim.ps1`. This affects only this one invocation; it does not change machine policy. |
| Security warning about an internet-downloaded file | `Unblock-File -Path .\Install-Striim.ps1`, then run again. |
| *"Striim requires 64-bit Windows. This system is 32-bit."* | The wizard refuses 32-bit systems — Striim does not support them. |

### Interview-time problems

| Symptom | Fix |
|---|---|
| *"Could not confirm \<version\> on the release server"* | Usually a typo — double-check against your Striim release notes (format `5.4.0.6`). If you're offline with a pre-staged `downloads\` bundle, or behind a proxy that blocks the check, answer yes to continue anyway. |
| *"Striim X is below 5.0"* | This wizard is 5.x-only. Use the legacy `msjetchecker.ps1` for 4.x. |
| *"Striim X is an early-5.0.x build from the Java 11 era"* | This wizard supports only the Java-17 line (~5.0.6+). Prefer upgrading Striim; you can confirm to continue anyway. |
| *"Cannot reach \<server\> on auth port 908x"* | The agent machine can't reach the Striim server right now. You can continue installing, but the agent won't connect until it's fixed — see [Network requirements](#network-requirements). Also check VPN status and that the server node is up. |
| Drive warning: under 500 MB or under 10% free | Pick a different drive from the table, or clear space. Striim should never run on a drive below 10% free. |
| *"MEM_MIN (...) must be <= MEM_MAX (...)"* | In the settings update flow, the min heap can't exceed the max heap. Re-enter both. |

### Execution failures

When a step fails you'll see `[R]etry / [S]kip / [A]bort` (or `[R]etry / [A]bort` for a critical step) plus the transcript path. **Retry first** — transient network and installer issues are common and every step is safe to retry.

| Symptom | Fix |
|---|---|
| *"Another MSI installation is already in progress"* (exit code 1618) | Windows Update or another installer holds the MSI mutex. Wait for it to finish (check for `msiexec` activity), then choose **Retry**. |
| *"Success — reboot required"* (exit code 3010) | Not a failure. The install continues; reboot the machine once the wizard finishes. |
| *"A newer version of this runtime is already installed"* (exit code 5100) | A VC++ 2015-2022 runtime is present. MSJet needs the 2015-2019 line — uninstall *Microsoft Visual C++ 2015-2022 Redistributable (x64)* via **Settings → Apps**, then choose **Retry**. |
| A download keeps failing | Check proxy/firewall rules for the hosts in [Network requirements](#network-requirements). Partially-downloaded files resume on Retry. As a last resort, build a bundle on another machine with [`-DownloadOnly`](#offline--air-gapped-installs) and copy `downloads\` over. |
| *"PATH resolves java to \<not 17\>"* warning | Another Java (8/11) sits earlier on the PATH. The agent uses whatever `java` resolves first. Reorder the machine PATH so JDK 17 wins, or ensure `JAVA_HOME` points at the JDK 17 directory. The warning names the exact offending Java and its location. |
| Keystore step fails | Re-run the wizard and use maintenance **[1] Verify** to see what's missing. The keystore scripts require the cluster `sys` password — verify it's correct and the cluster is reachable. |
| Checksum mismatch on a cached or downloaded file | A cached file that fails its SHA-256 is re-downloaded automatically. A freshly downloaded mismatch prompts: *"Checksum mismatch - keep the file anyway? (y/N)"* — answer no to discard and retry. |
| Elevated window closed / machine rebooted mid-install | Run the script again. Detection finds the partial install, and every step skips what's already done — the wizard picks up where it left off (a partially-extracted directory may need maintenance **[5] Clean reinstall**). |

### After the install

| Symptom | Fix |
|---|---|
| Agent doesn't appear under **Monitor → Agents** in the Striim console | 1) `Get-Service 'Striim Agent'` — is it Running? Start it if not. 2) Check `<install>\logs\` for connection errors. 3) Confirm cluster name and server address: maintenance **[3] Update Striim settings**. 4) Confirm the keystore/`sys` password were correct. 5) Re-check firewall ports (the verify report includes a live reachability check). |
| Service won't start | Check `<install>\logs\` for the agent's own error. Common causes: wrong cluster credentials, an over-large `MEM_MAX` for the machine's RAM, or the cluster being down. |
| New JDBC driver not being used | Drivers only load at service start. Maintenance **[2] Add/refresh JDBC drivers** restarts the service for you; if you copied a jar in manually, restart the service yourself: `Restart-Service 'Striim Agent'`. |
| Verify shows a red `[FAIL]` line | Each verify line maps to one requirement. Re-run the wizard — the install flow only acts on what's missing, so it functions as a targeted repair. |
| OLE DB driver version warning | An OLE DB Driver for SQL Server is installed but isn't a version this wizard has validated (`18.2.3.0`, `18.7.4.0`). It usually works; if you see MSJet connection issues, contact Striim support with the transcript. |
| Heap/cluster settings aren't taking effect | The service `wrapper.conf` overrides `agent.conf` at JVM start. Use maintenance **[3] Update Striim settings**, which rewrites both files in lockstep. |

### Still stuck?

Send Striim support the install transcript (`<install>\logs\install-*.log`). It contains the full step-by-step record of what happened — that single file answers most questions.

---

## Security notes

- **Passwords are never written to disk in plaintext.** Keystore and `sys` passwords are collected as masked secure input. When the wizard hands off to its elevated process, they're encrypted with Windows DPAPI under your user account — the plan file is useless to any other user or machine — and the file is deleted as soon as execution completes.
- **Transcripts never contain passwords.** The wizard echoes the plan into the transcript (mode, version, path, cluster, server, service, drivers) but excludes secrets by construction.
- **One elevation, reviewed first.** Nothing on the machine changes until you've approved the plan card, and admin rights are requested exactly once per flow.
- **Checksums.** Offline bundles ship with SHA-256 hashes in `manifest.json`; cached files with known hashes are re-verified before use.
- **No invasive system queries.** Prerequisite detection reads the registry directly; the wizard never queries `Win32_Product` (which is slow and can trigger MSI repair side effects on unrelated software).

---

## FAQ

**Is it safe to re-run?**
Yes — that's the design. Every step checks before it acts, so re-running skips everything already done. Re-running is also the repair procedure.

**Can I run it on a machine that already has Java 8 or 11?**
Yes. The wizard installs Java 17 alongside and warns you precisely if the older Java would still win on the PATH, including what to change.

**Does approving the plan install things I already have?**
No. Present components get "present" / "verify only" entries on the plan card; only missing items are downloaded and installed.

**How do I change the cluster or server address later?**
Maintenance menu **[3] Update Striim settings** — it rewrites both `agent.conf` and the service `wrapper.conf` and restarts the service.

**How do I add a JDBC driver later?**
Maintenance menu **[2] Add/refresh JDBC drivers**.

**How do I start, stop, or restart the service?**
Maintenance menu **[4] Manage service**, or directly with `Start-Service 'Striim Agent'` / `Stop-Service 'Striim Agent'` / `Restart-Service 'Striim Agent'`.

**Where does the wizard put its own files?**
Downloads in `downloads\` next to the script, transcripts in `<install>\logs\`, and a copy of the script itself in the install directory for future maintenance runs.

**How do I upgrade Striim?**
Re-run the wizard on the machine and choose **[6] Upgrade version** from the maintenance menu. It reads your current settings first, backs up your config/keystore/jars, swaps the install for the new version, and restores everything — one UAC prompt, no retyped settings.

**Does uninstall remove Java / VC++ / OLE DB?**
No — those are shared components other software may rely on. The uninstall summary prints one-line manual removal instructions for each if you want them gone.
