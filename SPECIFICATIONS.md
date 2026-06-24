# CASSENA CARE IR TOOLKIT — TECHNICAL SPECIFICATIONS
**Revision:** 2026-06-24  
**Repos:** `skrogman/Toolkit_App` (public) · `skrogman/Toolkit_Modules` (private)

---

## 1. PROJECT OVERVIEW

A PowerShell-based Incident Response Toolkit that presents operators with a terminal UI (TUI) listing available IR modules stored in a private GitHub repository. Modules are fetched on demand, never cached to disk, and dot-sourced into the current session for execution. A separate WPF debug window provides live timestamped logging that survives cross-user UAC elevation.

**Design priorities:**
- Zero local footprint for IR modules (streamed, not stored)
- Single-binary launcher (`Start-Toolkit.cmd`) — no pre-install step
- Works for standard domain users; elevates to a separate admin credential via UAC without losing the debug window
- Debug window survives the elevation boundary via a shared `C:\ProgramData` location

---

## 2. SYSTEM REQUIREMENTS

| Requirement | Minimum | Notes |
|---|---|---|
| PowerShell | 7.x (pwsh) | Auto-detects PS5 and relaunches as PS7 |
| .NET | 6+ (bundled with PS7) | WPF requires Windows; no Linux support |
| OS | Windows 10 / Server 2016+ | WPF, `GetConsoleWindow`, UAC verb all require Windows |
| Network | GitHub API + raw.githubusercontent.com | Required for module discovery and execution |
| Auth | GitHub PAT with `repo` scope | For private Toolkit_Modules repo; stored XOR-encrypted |

---

## 3. ARCHITECTURE

```
  Operator workstation
  ┌──────────────────────────────────────────────────────────────────┐
  │                                                                  │
  │  Start-Toolkit.cmd  ─── (polyglot: batch + PowerShell 7) ────  │
  │         │                                                        │
  │         ├─ [Shift held or flag file]                            │
  │         │       └──► Show-ConfigMenu (admin panel)              │
  │         │                  ├─ Option 1: Launch DebugWindow ──►  │─────────┐
  │         │                  ├─ Option 2: Encode PAT               │         │
  │         │                  ├─ Option 6: UAC elevate ──►         │         │
  │         │                  └─ Option 7: Auth + proceed           │         │
  │         │                                                        │         │
  │         └─ [normal boot]                                         │         │
  │               └──► Fetch Entry.ps1 from GitHub CDN              │         │
  │                         └──► TUI loop (Terminal.Gui v1.14.1)    │         │
  │                                   └──► [Enter] on module        │         │
  │                                             └──► Fetch + run     │         │
  │                                                   IR module      │         │
  │                                                                  │         │
  │  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─   │         │
  │                                                                  │         │
  │  [Separate pwsh -Sta process, launched by cassena user]         │◄────────┘
  │  ┌──────────────────────────────────┐                           │  WPF reads
  │  │  Toolkit Live Debug Console      │  Polls log file every     │  shared log
  │  │  (WPF / XAML)                    │◄─ 150ms via              │  from
  │  │  Filter │ Consolas dark textbox  │   DispatcherTimer         │  ProgramData
  │  │  Clear  │ Save As...             │                           │
  │  └──────────────────────────────────┘                           │
  │                                                                  │
  └──────────────────────────────────────────────────────────────────┘

  Cross-user IPC channel:  C:\ProgramData\CassenaCareToolkit\
  ┌──────────────────────┐         ┌──────────────────────┐
  │ toolkit_debug_active │◄─write──│ cassena session OR   │
  │       .log           │──read──►│ elevated admin/SYSTEM│
  │       .pid           │         │ session              │
  │ toolkit_admin_menu   │         └──────────────────────┘
  │       .flag          │
  └──────────────────────┘
```

**Why two repos:**  
`Toolkit_App` is public — the launcher, orchestrator, and debug module can be cloned or inspected freely. `Toolkit_Modules` is private — IR scripts stay off public GitHub; access requires a valid PAT + PIN.

---

## 4. REPOSITORY LAYOUT

```
Toolkit_App/  (public)
├── Start-Toolkit.cmd     Polyglot launcher, admin panel, token management
├── Entry.ps1             TUI orchestrator, module discovery and execution
└── DebugWindow.psm1      WPF debug console module

Toolkit_Modules/  (private, skrogman/Toolkit_Modules)
└── <ModuleName>/
    ├── Entry.ps1          Required — module entrypoint, fetched on demand
    └── *.ps1              Optional helper scripts (inventoried, not auto-run)
```

Each module directory in `Toolkit_Modules` must have an `Entry.ps1`. Its `.SYNOPSIS` comment block is read during TUI startup to populate the module description pane.

---

## 5. FILE LOCATIONS REFERENCE

### 5.1  Persistent Local Files  (survive reboots)

| Path | Purpose | Created by | Read by | Written by |
|---|---|---|---|---|
| `<ScriptRoot>\Start-Toolkit.cmd` | Polyglot launcher and admin panel | Manual deploy | OS CMD, PS7 | Operator / git |
| `<ScriptRoot>\Entry.ps1` | Local copy of TUI orchestrator | Manual deploy / git | `Start-Toolkit.cmd` (debug mode only) | Operator / git |
| `<ScriptRoot>\start-toolkit.cfg` | Encrypted user PAT profiles (JSON) | Option 2 | Options 4, 7, and production auth | Option 2 |

**`start-toolkit.cfg` structure:**
```json
{
  "PublicRepo": { "Owner": "skrogman", "Name": "Toolkit_App", "Branch": "main" },
  "Users": {
    "Alice": "<salt>|<base64-xor-payload>|<nonce-guid>"
  },
  "Settings": {
    "PublicOwner": "skrogman",
    "PublicRepo": "Toolkit_Modules",
    "PublicBranch": "main",
    "VerboseMode": "true"
  }
}
```

---

### 5.2  Runtime / Session Files  (`%TEMP%` — per user profile, not shared)

| Path | Purpose | Created by | Read by | Written by | Deleted by |
|---|---|---|---|---|---|
| `%TEMP%\toolkit_debug_ui.ps1` | WPF UI script written at runtime | `Start-DebugWindow` | `pwsh -Sta` child process | `Start-DebugWindow` | Not deleted (overwritten on next launch) |
| `%TEMP%\DebugWindow.psm1` | Cached module download | Option 1 / auto-reconnect | `Import-Module` | `Invoke-RestMethod` | Not deleted |
| `%TEMP%\TerminalGui_Standalone_Master\Terminal.Gui.zip` | NuGet package download | Entry.ps1 [1] first-run | `Expand-Archive` | `Invoke-WebRequest` | Not deleted |
| `%TEMP%\TerminalGui_Standalone_Master\NStack.Core.zip` | NuGet package download | Entry.ps1 [1] first-run | `Expand-Archive` | `Invoke-WebRequest` | Not deleted |
| `%TEMP%\TerminalGui_Standalone_Master\Assemblies\Terminal.Gui.dll` | Terminal.Gui TUI framework | `Expand-Archive` | `Assembly::LoadFrom` | — | Not deleted |
| `%TEMP%\TerminalGui_Standalone_Master\Assemblies\NStack.dll` | NStack Unicode library (Terminal.Gui dep) | `Expand-Archive` | `Assembly::LoadFrom` | — | Not deleted |
| `%TEMP%\toolkit_module_run.log` | Per-run transcript of module console output | Entry.ps1 [4] | Entry.ps1 transcript parser | `Start-Transcript` | Entry.ps1 [4] after parsing |

**Why `%TEMP%` for these:** These files are session-local and only accessed by the user who creates them. They do not need to cross the UAC user boundary. `toolkit_debug_ui.ps1` is launched as a child process of the same user; the Terminal.Gui assemblies are cached once and reused across sessions of the same user.

---

### 5.3  Shared IPC Files  (`C:\ProgramData\CassenaCareToolkit\` — cross-user, cross-elevation)

| Path | Purpose | Created by | Read by | Written by | Deleted by |
|---|---|---|---|---|---|
| `...\toolkit_debug_active.log` | Append-only debug message log | `Start-DebugWindow` (truncates to empty on fresh launch) | WPF `DispatcherTimer` every 150ms | Any session calling `Write-DebugWindow` | Not deleted; truncated on next fresh launch |
| `...\toolkit_debug_active.pid` | PID of the running WPF process | `Start-DebugWindow` | `Write-DebugWindow`, `Test-DebugWindowAlive`, auto-reconnect | `Start-DebugWindow` | Not deleted; overwritten on next launch |
| `...\toolkit_admin_menu.flag` | Signals elevated session to open admin menu | Option 6 (written inside `try`) | Startup of any new `Start-Toolkit.cmd` instance | Option 6 | Startup (immediately after reading); Option 6 `catch` if UAC fails |

**Why `C:\ProgramData`:** `$env:TEMP` is user-profile-specific. When UAC elevation uses a different credential (over-the-shoulder domain admin), the elevated process has a different `%TEMP%`. `C:\ProgramData` resolves to the same absolute path for all users and all integrity levels including SYSTEM. Files cassena creates there automatically receive SYSTEM and Administrators `Full Control` via ACL inheritance from `C:\ProgramData`, so the elevated session can read and write without any manual permission setup.

**Directory creation:** `C:\ProgramData\CassenaCareToolkit\` is created automatically in two places — at startup of `Start-Toolkit.cmd` (before flag file check) and inside `Start-DebugWindow` — so it exists before any of these files are touched.

---

### 5.4  Network Resources

| URL | Purpose | Called by | Auth required |
|---|---|---|---|
| `https://raw.githubusercontent.com/skrogman/Toolkit_App/main/DebugWindow.psm1?t=<guid>` | Download debug module | Option 1, auto-reconnect | No (public repo) |
| `https://raw.githubusercontent.com/skrogman/Toolkit_App/main/Entry.ps1?t=<guid>` | Download TUI orchestrator | `Start-Toolkit.cmd` production path | No (public repo) |
| `https://www.nuget.org/api/v2/package/Terminal.Gui/1.14.1` | Download Terminal.Gui NuGet package | Entry.ps1 [1] first-run only | No |
| `https://www.nuget.org/api/v2/package/NStack.Core/1.0.7` | Download NStack NuGet package | Entry.ps1 [1] first-run only | No |
| `https://api.github.com/repos/skrogman/Toolkit_Modules/contents?ref=main` | List root directories (module names) | Entry.ps1 [2] | Yes — Bearer PAT |
| `https://api.github.com/repos/skrogman/Toolkit_Modules/contents/<dir>?ref=main` | List files in each module directory | Entry.ps1 [2] | Yes — Bearer PAT |
| `https://api.github.com/repos/skrogman/Toolkit_Modules/contents/<dir>/<sub>?ref=main` | List files in subdirectories | Entry.ps1 [2] | Yes — Bearer PAT |
| `<file.download_url>` (raw GitHub) | Fetch `.ps1` source to extract `.SYNOPSIS` | Entry.ps1 [2] | Yes — Bearer PAT |
| `https://raw.githubusercontent.com/skrogman/Toolkit_Modules/main/<module>/Entry.ps1?t=<guid>` | Fetch and execute IR module | Entry.ps1 [4] | Yes — Bearer PAT |

**Cache-busting:** All CDN fetches append `?t=<guid>` to force GitHub's CDN to bypass cached responses. This ensures debug mode always gets the current file.

---

### 5.5  Named System Objects

| Name | Type | Purpose | Held by |
|---|---|---|---|
| `Global\SkrogmanIRToolkitEnclaveLock` | Named Mutex | Prevents two toolkit instances running simultaneously | `Start-Toolkit.cmd` main body; released in `finally` block |

The mutex is `Global\` prefixed so it spans Terminal Services sessions. If a second instance detects the mutex is taken, the operator is offered the choice to co-exist (bypass) or kill the old instance and take the lock.

---

## 6. MODULE SPECIFICATIONS

---

### 6.1  `Start-Toolkit.cmd`

**Role:** Entry point. Polyglot file that runs as both a Windows batch script (which hands off to PowerShell) and a PowerShell script. Contains the admin panel, token management, engine handoff, single-instance enforcement, and production auth flow.

**Inputs:** None (interactive). Reads `start-toolkit.cfg`, `$env:ProgramData\CassenaCareToolkit\*.flag`, keyboard state at boot.

**Outputs:** Sets global variables consumed by `Entry.ps1`, launches child processes.

---

#### Batch / CMD polyglot section  (lines 1–16)

```
PSEUDOCODE: Batch polyglot header
  IF pwsh.exe exists in PATH:
    run: pwsh -NoProfile -ExecutionPolicy Bypass -Command "read entire .cmd file as string; Invoke-Expression it"
  ELSE:
    run: powershell.exe (same command — PS5 fallback)
  ECHO "execution complete"
  PAUSE  (holds window open if run outside a terminal)
```

**Purpose:** Allows the file to be double-clicked or `Start-Process -Verb RunAs` as a `.cmd` file while the actual logic is PowerShell. The `<# ... #>` comment block is valid PowerShell; the `goto:eof` short-circuits batch before reaching the `#>` line.

**Why `Invoke-Expression` instead of `-File`:** `-File` cannot execute `.cmd` files as PowerShell. Reading the file's own bytes and evaluating them sidesteps this. `%~f0` is the full path to the batch file.

---

#### [0] Hardware Key Register & State Inheritance  (lines 33–57)

```
PSEUDOCODE: Determine if Shift key was held at launch
  TRY:
    Add-Type: Win32Keyboard with P/Invoke to user32.dll GetKeyState(VK_SHIFT = 0x10)
    ShiftPressed = (GetKeyState(0x10) AND 0x8000) != 0
  CATCH:
    ShiftPressed = Windows.Forms.Control.ModifierKeys check

  IF env:TK_FORCE_MENU == "1":
    ShiftPressed = true   ← carries state across PS5→PS7 engine handoff

  SharedDir = C:\ProgramData\CassenaCareToolkit\
  CREATE SharedDir if not exists

  IF toolkit_admin_menu.flag exists in SharedDir:
    ShiftPressed = true
    DELETE the flag   ← consumed immediately; prevents stale re-trigger
```

**Inputs:** VK_SHIFT hardware state, `$env:TK_FORCE_MENU`, `toolkit_admin_menu.flag`  
**Output:** `$ShiftPressed` boolean  
**Side effects:** Deletes flag file if present. Creates `C:\ProgramData\CassenaCareToolkit\` if absent.

---

#### [1] Engine Handoff: PS5 → PS7  (lines 61–82)

```
PSEUDOCODE: Ensure PowerShell 7+ is running
  IF PSVersion.Major < 7:
    PRINT "legacy PS5 detected — handing off"
    IF ShiftPressed: SET env:TK_FORCE_MENU = "1"  (carries state over process boundary)
    IF pwsh.exe in PATH:
      Start-Process pwsh.exe "-File <this script>" -Wait -NoNewWindow
      EXIT with child's exit code
    ELSE:
      PRINT fatal error: PS7 not installed
      EXIT
```

**Inputs:** `$PSVersionTable.PSVersion`, `$ShiftPressed`  
**Outputs:** None (process replacement)  
**Why:** Terminal.Gui v1.14.1 uses `Terminal.Gui.Key` enum values that violate CLS compliance rules. `Add-Type` in PS5 rejects them. `Assembly::LoadFrom` in PS7 bypasses that check.

---

#### `New-UserTokenConfig`  (lines 85–129)

```
PSEUDOCODE: Enroll a new user PAT under a PIN
  PROMPT: Username (string label for this profile)
  PROMPT: GitHub PAT (plain text, paste)
  PROMPT: PIN (SecureString, masked)

  VALIDATE: Username, PAT, and PIN must all be non-empty

  Salt   = first 16 chars of a new GUID (no dashes)
  SecretKey = (PIN + Salt) padded or truncated to exactly 32 chars
  KeyBytes  = UTF-16LE encoding of SecretKey

  FOR each byte in UTF-16LE(PAT):
    XOR with KeyBytes[i mod 32]
  EncodedPayload = Base64(XOR result)

  FinalConfigString = "<Salt>|<EncodedPayload>|<random nonce GUID>"

  READ existing start-toolkit.cfg (or start fresh)
  SET config.Users.<Username> = FinalConfigString
  WRITE config back to start-toolkit.cfg (UTF-8, JSON)
```

**Inputs:** Interactive (Username, PAT, PIN)  
**Outputs:** Updates `start-toolkit.cfg` on disk  
**Error conditions:** Blank username/PAT/PIN → prints error, returns without writing. File write failure → unhandled exception propagates to `Show-ConfigMenu`.

**Token format stored:** `<16-char-salt>|<base64-xor-blob>|<nonce>` — the nonce is vestigial (not used in decryption) and reserved for future revocation tagging.

---

#### `Get-DecodedToken($Config)`  (lines 131–166)

```
PSEUDOCODE: Authenticate a stored profile and recover the PAT
  PROMPT: Username
  VERIFY: Username exists as key in config.Users — THROW if not found
  PROMPT: PIN (SecureString, masked)

  EncodedToken = config.Users.<Username>

  IF token contains pipe character:        ← new format (Salt|Payload|Nonce)
    Split on "|" → [Salt, Payload, Nonce]
    SecretKey = (PIN + Salt) padded/truncated to 32 chars
    MixedBytes = Base64Decode(Payload)
    KeyBytes   = UTF-16LE(SecretKey)
    FOR each byte: XOR with KeyBytes[i mod 32]
    RETURN UTF-16LE decode of result, trimmed, null chars stripped
  ELSE:                                    ← legacy format (raw base64)
    RETURN UTF-8 decode of Base64Decode(token), trimmed
```

**Inputs:** `$Config` (parsed JSON object), interactive Username + PIN  
**Outputs:** Plain-text GitHub PAT string  
**Error conditions:** Profile not found → throws (caught by caller). Wrong PIN → returns garbled bytes (no error; GitHub API will 401 downstream). Empty token → returns empty string.

---

#### `Test-DebugWindowAlive`  (lines 169–176)

```
PSEUDOCODE: Check if the debug WPF process is still running
  pidFile = C:\ProgramData\CassenaCareToolkit\toolkit_debug_active.pid
  IF pidFile does not exist: RETURN false
  pid = parse int from pidFile; IF parse fails: RETURN false
  IF pid <= 0: RETURN false
  proc = Get-Process -Id pid (suppress errors)
  RETURN (proc is not null AND proc.HasExited == false)
```

**Inputs:** None  
**Outputs:** Boolean  
**Called by:** Admin menu badge display (every menu repaint), Option 1 "already open" guard, Option 7 debug mode flag

---

#### `Get-ConsoleWindowRect`  (lines 178–193)

```
PSEUDOCODE: Get pixel coordinates of the console window
  Add-Type: C# class ConWin with:
    - kernel32 GetConsoleWindow() -> HWND
    - user32 GetWindowRect(HWND, out RECT) -> bool
    - RECT struct: Left, Top, Right, Bottom (int)

  h = GetConsoleWindow()
  r = new RECT
  GetWindowRect(h, ref r)
  RETURN r
  ON ANY EXCEPTION: RETURN null
```

**Inputs:** None  
**Outputs:** `RECT` struct with pixel coordinates of console window, or `$null` on failure  
**Used by:** Option 1 — positions the debug window just below the console: `X = rect.Left`, `Y = rect.Bottom + 5`

---

#### `Show-ConfigMenu`  (lines 195–356)

```
PSEUDOCODE: Admin panel — runs before TUI when Shift held at boot

  --- AUTO-RECONNECT (runs once, before menu loop) ---
  pidFile = C:\ProgramData\CassenaCareToolkit\toolkit_debug_active.pid
  logFile = C:\ProgramData\CassenaCareToolkit\toolkit_debug_active.log
  IF both files exist:
    savedPid = read pidFile
    wpfProc  = Get-Process savedPid
    IF wpfProc is alive:
      IF DebugWindow.psm1 not in %TEMP%: download from GitHub CDN
      Import-Module DebugWindow.psm1 (Force)
      SET Global:DebugSync = {LogFile, Running:true, WpfProc}  ← must be AFTER import
      WRITE reconnect banner directly to logFile (bypasses sync check)
      PRINT "[+] Debug console reconnected"

  --- MENU LOOP ---
  WHILE true:
    CLEAR screen
    $_isAdmin = check current process token for Administrators group
    $_dbgTag  = Test-DebugWindowAlive ? " [Running]" : ""
    $_admTag  = $_isAdmin ? " [Elevated]" : " [Not Elevated]"
    PRINT menu with live badges

    READ choice

    "1" → Open Debug Console:
      IF Test-DebugWindowAlive: PRINT "already open"; CONTINUE
      DOWNLOAD DebugWindow.psm1 from GitHub to %TEMP% (with cache-buster GUID)
      Import-Module
      rect = Get-ConsoleWindowRect
      Start-DebugWindow -X rect.Left -Y (rect.Bottom + 5)
      SLEEP 800ms (let WPF window initialize)
      Write-DebugWindow header messages

    "2" → Roll / Encode New User PAT:
      CALL New-UserTokenConfig

    "3" → List Users:
      IF config exists: parse JSON; print Users property keys
      ELSE: print "no config"

    "4" → Exit Admin Panel (proceed to production):
      RETURN   ← caller continues to production ingestion

    "5" → Abort:
      EXIT (process)

    "6" → Relaunch as Administrator:
      IF already admin: PRINT warning; Write-DebugWindow WARN; SLEEP 2s
      ELSE:
        Write-DebugWindow "relaunching" WARN; SLEEP 500ms
        flagPath = C:\ProgramData\CassenaCareToolkit\toolkit_admin_menu.flag
        TRY:
          WRITE "1" to flagPath   ← inside try; only persists if launch succeeds
          Start-Process Start-Toolkit.cmd -Verb RunAs (UAC prompt appears)
          SLEEP 400ms
          Environment::Exit(0)   ← forceful exit; no cleanup needed
        CATCH:
          DELETE flagPath   ← clean up stale flag if UAC was denied
          PRINT error details + tip
          Write-DebugWindow ERROR

    "7" → Authenticate & Launch:
      IF no config file: PRINT "create user first"; CONTINUE
      TRY:
        cfg = read + parse start-toolkit.cfg
        token = Get-DecodedToken(cfg)
        SET global:ToolkitAuthHeader, ToolkitPAT, ToolkitRepoOwner, ToolkitTargetRepo, ToolkitBranch
        SET global:ToolkitDebugMode = Test-DebugWindowAlive
        IF Write-DebugWindow available: log auth details + test GitHub API connectivity
        RETURN   ← caller continues to production ingestion with globals pre-set
      CATCH:
        PRINT error; wait for Enter
```

**Inputs:** Interactive, `start-toolkit.cfg`, PID/log files in ProgramData  
**Outputs:** Sets `$global:ToolkitAuthHeader`, `$global:ToolkitPAT`, `$global:ToolkitRepoOwner`, `$global:ToolkitTargetRepo`, `$global:ToolkitBranch`, `$global:ToolkitDebugMode` (only via option 7)

---

#### [2] Single-Instance Lock  (lines 358–384)

```
PSEUDOCODE: Enforce only one toolkit instance per machine
  MutexName = "Global\SkrogmanIRToolkitEnclaveLock"
  TRY acquire mutex (CreatedNew flag indicates whether we got it)

  IF mutex was already held (CreatedNew == false):
    PROMPT: allow multi-instance [Y] or kill old instance [N]
    IF "Y":
      dispose mutex (run without lock)
    ELSE:
      GET all pwsh/powershell/cmd processes with "Start-Toolkit" in command line
      KILL each one that is not the current PID
      SLEEP 600ms
      RE-ACQUIRE mutex

  IF ShiftPressed:
    CALL Show-ConfigMenu
    CLEAR screen
```

**Inputs:** None  
**Outputs:** `$Mutex` object held for the duration of the session  
**Released:** `finally` block at script end  
**Note:** `Global\` prefix means the mutex spans multiple Terminal Services / RDP sessions on the same machine.

---

#### [3] / [4] / [5] Production Ingestion  (lines 392–429)

```
PSEUDOCODE: Load and execute the TUI orchestrator

  [3] Validate config:
    IF start-toolkit.cfg does not exist:
      THROW with tip to hold Shift on boot

  [4] Auth (skip if globals already set by option 7):
    IF global:ToolkitAuthHeader is null:
      cfg = read + parse start-toolkit.cfg
      token = Get-DecodedToken(cfg)
      SET global:ToolkitAuthHeader, env:GITHUB_TOKEN, global:ToolkitPAT,
          global:ToolkitRepoOwner, global:ToolkitTargetRepo, global:ToolkitBranch

  [5] Load Entry.ps1:
    LocalEntry = <ScriptRoot>\Entry.ps1
    IF global:ToolkitDebugMode AND LocalEntry exists:
      MasterCode = read local file   ← no CDN; immediate reflection of edits
      Write-DebugWindow "Loading local Entry.ps1 (debug mode)"
    ELSE:
      MasterCode = Invoke-RestMethod from GitHub CDN (with cache-buster GUID)

    ScriptBlock = [scriptblock]::Create(MasterCode)
    CLEAR screen
    DOT-SOURCE ScriptBlock with -AuthHeader -RepoOwner -TargetRepo -Branch

  ON EXCEPTION: PRINT error; wait for Enter
  FINALLY: ReleaseMutex; Dispose
```

**Inputs:** `start-toolkit.cfg`, globals from option 7 if set  
**Outputs:** Dot-sources Entry.ps1 — execution continues inside it

---

### 6.2  `DebugWindow.psm1`

**Role:** PowerShell module providing three exported functions. The actual WPF UI runs as a completely separate `pwsh -Sta` process; this module handles launching it, writing to its shared log file, and stopping it. Loaded on demand from GitHub (not pre-installed), cached in `%TEMP%`.

**Why a separate process for WPF:** WPF requires STA (single-threaded apartment) COM threading. The main toolkit session uses a different threading model. Sharing a runspace and thread would deadlock. Separate `pwsh -Sta` process communicates via a shared append-only log file.

**Module-level initialization  (lines 1–5):**  
Creates `$Global:DebugSync` synchronized hashtable (`LogFile`, `Running`, `WpfProc`) for legacy compat. `Write-DebugWindow` no longer depends on this — it uses PID file directly — but `Start-DebugWindow` and `Stop-DebugWindow` still update it.

---

#### `Start-DebugWindow`  (lines 7–149)

```
PSEUDOCODE: Launch or reconnect to the WPF debug console process
  INPUT:  [int]$X = -1,  [int]$Y = -1   (screen position for window; -1 = auto)
  OUTPUT: None (side effects only)

  sharedDir = C:\ProgramData\CassenaCareToolkit\
  CREATE sharedDir if not exists
  logFile  = sharedDir\toolkit_debug_active.log
  pidFile  = sharedDir\toolkit_debug_active.pid
  uiScript = %TEMP%\toolkit_debug_ui.ps1

  --- RECONNECT PATH ---
  IF pidFile exists:
    savedPid = parse int from pidFile
    existing = Get-Process savedPid
    IF existing is alive:
      UPDATE Global:DebugSync (LogFile, WpfProc, Running=true)
      PRINT "Reconnected to existing debug console (PID <n>)"
      RETURN   ← no new process

  --- FRESH LAUNCH PATH ---
  WRITE empty string to logFile   ← truncates to zero length; clears old entries
  WRITE wpfCode (here-string, see WPF UI spec below) to uiScript

  proc = Start-Process pwsh:
    args: -NoProfile -ExecutionPolicy Bypass -Sta -File uiScript logFile X Y
    -WindowStyle Hidden (console-less)
    -PassThru (returns process object)

  WRITE proc.Id to pidFile
  UPDATE Global:DebugSync
  PRINT "Debug console launched (PID <n>)"
```

**Inputs:** Optional X/Y pixel coordinates  
**Outputs:** None (side effects: creates files, spawns process, updates globals)  
**Error conditions:** If `pwsh` is not found, `Start-Process` throws — not caught here (propagates to option 1's catch block in `Show-ConfigMenu`). If ProgramData dir creation fails silently, subsequent file writes will fail and throw.

---

#### WPF UI Process  (`toolkit_debug_ui.ps1`, lines 31–133)

This script is written to `%TEMP%\toolkit_debug_ui.ps1` at launch and executed by `pwsh -Sta`.

```
PSEUDOCODE: Standalone WPF log tail window
  INPUT params: [string]$LogFile, [int]$X = -1, [int]$Y = -1

  Add-Type PresentationFramework, WindowsBase

  BUILD XAML window:
    Row 0: ToolBar
      - Label "Filter:"
      - TextBox [txtSearch] width=260
      - Button [btnFilter] "Apply"
      - Button [btnClearFilter] "Reset"
    Row 1: TextBox [txtLogs]
      - Consolas 12pt, dark (#18181B bg, #A1A1AA fg)
      - ReadOnly, wrapping, auto-scrollbar
    Row 2: StatusBar
      - Button [btnClear] "Clear"
      - Button [btnSave] "Save As..."

  Load XAML via XmlNodeReader + XamlReader::Load

  allLines    = List<string>   ← in-memory copy of all lines received
  ActiveFilter = ""
  LastPos      = 0L            ← byte position in log file; incremental reads

  UpdateDisplay scriptblock:
    IF filter is blank:
      txtLogs.Text = join allLines with CRLF
    ELSE:
      txtLogs.Text = join (allLines WHERE line contains filter) with CRLF
    txtLogs.ScrollToEnd()

  DispatcherTimer (interval: 150ms):
    TRY:
      OPEN logFile with FileShare.ReadWrite (allows concurrent writes)
      IF file.Length > LastPos:
        SEEK to LastPos
        READ remaining bytes as UTF-8 string
        UPDATE LastPos = current stream position
        CLOSE file
        SPLIT on newline → new lines
        ADD each non-empty line to allLines
        CALL UpdateDisplay
      ELSE: CLOSE file
    CATCH: (silently ignore — file may be locked momentarily)
  START timer

  btnFilter.Click:        ActiveFilter = txtSearch.Text; UpdateDisplay
  btnClearFilter.Click:   txtSearch.Text = ""; ActiveFilter = ""; UpdateDisplay
  btnClear.Click:         allLines.Clear(); txtLogs.Clear(); LastPos = 0L
  btnSave.Click:
    SaveFileDialog → user picks path
    File.WriteAllLines(chosen path, allLines.ToArray())
    ON FAIL: MessageBox with error

  window.Closed:
    timer.Stop()
    Dispatcher.CurrentDispatcher.InvokeShutdown()   ← unblocks Dispatcher::Run

  IF X >= 0 AND Y >= 0:
    window.WindowStartupLocation = Manual
    window.Left = X; window.Top = Y

  window.ShowActivated = false   ← opens without stealing focus
  window.Show()
  Dispatcher::Run()              ← blocks until InvokeShutdown called
```

**Inputs:** `$LogFile` path, optional `$X` / `$Y`  
**Outputs:** None (runs until window closed)  
**Threading:** STA is mandatory — WPF requires it. Launched as `-Sta` via `Start-Process`.  
**File access pattern:** Opens log file in `ReadWrite` share mode so main process can append while WPF reads. Uses `StreamReader` on top of the `FileStream` with seek to avoid re-reading the whole file on each tick.

---

#### `Write-DebugWindow`  (lines 151–171)

```
PSEUDOCODE: Write a timestamped log line to the debug window
  INPUT:
    [string]$Message  (mandatory, pipeline-capable)
    [string]$Level    (INFO | WARN | ERROR | DEBUG, default INFO)

  logFile = C:\ProgramData\CassenaCareToolkit\toolkit_debug_active.log
  pidFile = C:\ProgramData\CassenaCareToolkit\toolkit_debug_active.pid

  ts   = Get-Date "yyyy-MM-dd HH:mm:ss.fff"
  line = "[<ts>] [<Level padded to 5>] <Message>"

  wrote = false

  IF both logFile and pidFile exist:
    pid = parse int from pidFile
    IF pid > 0:
      proc = Get-Process pid (suppress errors)
      IF proc is alive AND not exited:
        TRY: AppendAllText(logFile, line + CRLF, UTF-8)
             wrote = true
        CATCH: (silent — will fall through to Write-Host)

  IF NOT wrote:
    Write-Host line (DarkGray)   ← fallback: debug window is down
```

**Inputs:** Message string, Level enum  
**Outputs:** None (side effects: appends to log file, or console fallback)  
**Key design point:** Self-sufficient — does not depend on `$Global:DebugSync`. Every call does its own PID file check. This means it works correctly immediately after elevation to a different user account, even if module-level globals were reset by a re-import.  
**Pipeline:** Accepts `ValueFromPipeline`, so `"message" | Write-DebugWindow` works.

---

#### `Stop-DebugWindow`  (lines 173–179)

```
PSEUDOCODE: Request graceful WPF window close
  IF Global:DebugSync.WpfProc is not null AND not exited:
    TRY: proc.CloseMainWindow()   ← posts WM_CLOSE; triggers window.Closed handler
    CATCH: (silent)
  SET Global:DebugSync.Running = false
  PRINT "Debug console stopped."
```

**Inputs:** None  
**Outputs:** None  
**Limitation:** Only works if `$Global:DebugSync.WpfProc` is set (i.e., the module launched the window in this session). Does not use the PID file. If the process was reconnected from a previous session, `CloseMainWindow` may not work — the operator can close the WPF window manually.

---

### 6.3  `Entry.ps1`

**Role:** TUI orchestrator. Fetched from GitHub CDN and dot-sourced by `Start-Toolkit.cmd`. Discovers IR modules via GitHub API, builds the Terminal.Gui TUI, handles navigation, fetches and executes selected modules, and captures module output for display in the right pane.

**Parameters:**
| Parameter | Type | Default | Source |
|---|---|---|---|
| `$AuthHeader` | `[hashtable]` | `$null` | Passed from `Start-Toolkit.cmd` or inherited from globals |
| `$RepoOwner` | `[string]` | `"skrogman"` | Overridden by `$global:ToolkitRepoOwner` |
| `$TargetRepo` | `[string]` | `"Toolkit_Modules"` | Overridden by `$global:ToolkitTargetRepo` |
| `$Branch` | `[string]` | `"main"` | Overridden by `$global:ToolkitBranch` |
| `$CatchAllParameters` | | | Silently absorbs unexpected params from callers |

Global inheritance order for `$AuthHeader`: explicit param → `$global:ToolkitAuthHeader` → `$global:ToolkitPAT` → `$env:GITHUB_TOKEN`.

---

#### `Write-Log`  (lines 26–33)

```
PSEUDOCODE: Route internal log messages to debug window or console
  INPUT: $Level (string), $Message (string)

  IF Write-DebugWindow command exists in current session:
    safeLevel = $Level if valid (INFO/WARN/ERROR/DEBUG), else "INFO"
    Write-DebugWindow "[$Level] $Message" -Level safeLevel
  ELSE:
    Write-Host "[HH:mm:ss] [$Level] $Message" (DarkGray)
```

**Note:** Does not check `$Global:DebugSync`. Simply delegates to `Write-DebugWindow` if the function is available, which handles its own liveness check internally.

---

#### [1] Dependency Bootstrapper  (lines 35–58)

```
PSEUDOCODE: Ensure Terminal.Gui assemblies are available
  TempDir    = %TEMP%\TerminalGui_Standalone_Master
  ExtractDir = TempDir\Assemblies

  IF ExtractDir does not exist:
    Write-Log INFO "First run — downloading Terminal.Gui framework..."
    CREATE ExtractDir
    Invoke-WebRequest nuget/Terminal.Gui/1.14.1  → TempDir\Terminal.Gui.zip
    Invoke-WebRequest nuget/NStack.Core/1.0.7    → TempDir\NStack.Core.zip
    Expand-Archive Terminal.Gui.zip → ExtractDir
    Expand-Archive NStack.Core.zip  → ExtractDir

  NStackDll = find NStack.dll    recursively in ExtractDir
  GuiDll    = find Terminal.Gui.dll recursively in ExtractDir

  TRY: Assembly::LoadFrom(NStackDll)   ← LoadFrom bypasses CLS type check
  TRY: Assembly::LoadFrom(GuiDll)
```

**Inputs:** None  
**Outputs:** Terminal.Gui and NStack assemblies loaded into the current AppDomain  
**Error conditions:** Network failure on first run throws and is caught by the outer `try/catch` in the script. Subsequent runs reuse cached zips. `Assembly::LoadFrom` errors are silently swallowed — if the DLL is corrupt, a `TypeNotFoundException` will surface later when Terminal.Gui types are referenced.  
**Why `LoadFrom` not `Add-Type`:** `Add-Type` triggers .NET CLS compliance validation which rejects `Terminal.Gui.Key` enum values. `Assembly::LoadFrom` skips that validation.

---

#### [2] Dynamic Module Discovery  (lines 60–154)

```
PSEUDOCODE: Build module list from Toolkit_Modules GitHub API
  ApiBase = https://api.github.com/repos/<RepoOwner>/<TargetRepo>

  GET ApiBase/contents?ref=<Branch>   (authenticated)
  Dirs = response items WHERE type == "dir" AND name doesn't start with "."
  SORT Dirs by name

  FOR each Dir:
    Synopsis = "IR & Admin module."   (default if no comment block found)
    Scripts  = []

    GET ApiBase/contents/<Dir.name>?ref=<Branch>   (authenticated)
    Ps1Files = items WHERE type == "file" AND name ends ".ps1"

    FOR each Ps1File:
      FETCH raw content via download_url   (authenticated)
      TRY extract from comment block:
        PREFER .SYNOPSIS section
        FALL BACK to .DESCRIPTION section
        Desc = first matching section, whitespace-collapsed to one line

      IF filename == "Entry.ps1":
        Synopsis = Desc  (module's main synopsis)
      ELSE:
        Scripts.Add({Name: filename without .ps1, Desc})

    SubDirs = items WHERE type == "dir"
    FOR each SubDir:
      GET ApiBase/contents/<Dir.name>/<SubDir.name>
      FOR each .ps1 file in SubDir:
        FETCH + extract Desc same as above
        Scripts.Add({Name: "<SubDir>/<file>", Desc})

    global:Modules.Add({Name: Dir.name, Synopsis, Scripts})

  global:MenuLabels = ["  <name>" for each module] + ["  ─── Exit Toolkit ───"]
```

**Inputs:** `$AuthHeader`, `$RepoOwner`, `$TargetRepo`, `$Branch`  
**Outputs:** `$global:Modules` (List of hashtables), `$global:MenuLabels` (ArrayList of strings)  
**Error conditions:** GitHub API returns 401/403 → entire discovery fails with ERROR log; `$global:Modules` stays empty; TUI will show only the Exit option. Per-module inventory failure → WARN log; module is still added with default synopsis. Per-file fetch failure → silent; description stays blank.  
**Performance note:** N+2 API calls plus one raw download per `.ps1` file. For a repo with 5 modules averaging 3 scripts each = ~22 HTTP requests at startup.

---

#### [3] TUI Loop  (lines 157–332)

```
PSEUDOCODE: Terminal.Gui TUI — runs each iteration until a module is chosen or exit

  global:ExitMaster   = false
  global:TargetModule = null

  WHILE NOT global:ExitMaster:

    --- ENVIRONMENT PREP ---
    SAVE and CLEAR env:TERM, env:COLORTERM
    (Terminal.Gui probes these to detect Linux terminal capabilities;
     on Windows they cause libc lookup failures)

    --- INIT ---
    Application::Init()   ← initializes Terminal.Gui with Windows console driver
    RESTORE env:TERM, env:COLORTERM

    --- BUILD UI ---
    Color schemes:
      SchemeApp:    White on Blue, Black on Cyan (focus), BrightYellow on Blue (hot)
      SchemeHeader: Black on Cyan
      SchemeInfo:   BrightCyan on Blue

    Win = Window (fills screen)
    HeaderLabel = Label (row 0, full width, SchemeHeader)
      text: "CASSENA CARE IR TOOLKIT | Operator: <USERNAME> | Auth: <Active|Anonymous> | [Shift+Boot] → Admin"

    ListFrame = FrameView "  MODULES  " (left, 36% wide)
    ListView: source = global:MenuLabels

    InfoFrame = FrameView "  MODULE INFO  " (right of ListFrame, fills rest)
    global:InfoView = TextView (ReadOnly, SchemeInfo, fills InfoFrame)

    NavLabel = Label at bottom row (full width, SchemeHeader)
      text: "↑↓ Navigate   Enter: Launch Module   Vault: <repo> [<branch>]"

    --- CONTENT ---
    global:BuildInfoPane scriptblock (see below)

    --- INITIAL DISPLAY ---
    IF global:LastModuleOutput is set:
      InfoFrame.Title = "  <LAST MODULE NAME> — OUTPUT  "
      InfoView.Text   = module run transcript (cleaned)
      global:LastModuleOutput = null   ← consumed; will not show again next iteration
    ELSE:
      CALL BuildInfoPane(Index=0)

    --- EVENTS ---
    ListView.SelectedItemChanged → CALL BuildInfoPane(event.Item)
    ListView.OpenSelectedItem:
      IF item is last (Exit): global:ExitMaster = true
      ELSE: global:TargetModule = Modules[item].Name
      Application::RequestStop()

    --- RUN ---
    Application::Run()       ← blocks until RequestStop called
    Application::Shutdown()  ← tears down Terminal.Gui; restores console

    → fall through to [4] if TargetModule is set
```

**Inputs:** `$global:Modules`, `$global:MenuLabels`, `$global:LastModuleOutput`  
**Outputs:** `$global:TargetModule` (set when user selects a module), `$global:ExitMaster` (set when user selects Exit)  
**Why `while` loop re-initializes everything:** Terminal.Gui does not support reinitializing after `Shutdown`. The only way to show the TUI again after a module run is to call `Init()` fresh. All UI objects must be recreated.

---

#### `$global:BuildInfoPane` scriptblock  (lines 242–292)

```
PSEUDOCODE: Populate the right pane with module metadata
  INPUT: $Index (int) — zero-based index into global:Modules

  IF Index >= Modules.Count:   ← Exit item selected
    text = EXIT header + description + "Press [Enter] to confirm"
  ELSE:
    m = Modules[Index]
    text = module name (uppercase) + separator
    text += synopsis word-wrapped at ~40 chars
    text += script inventory:
      "◆ Entry.ps1"  (always present)
      for each script in m.Scripts:
        "◇ <name>  <truncated desc>"
    text += Vault / Branch / Path metadata
    text += "Press [Enter] to launch."

  global:InfoView.Text = text
  global:InfoView.SetNeedsDisplay()
```

**Inputs:** `$Index`, reads `$global:Modules`  
**Outputs:** Updates `$global:InfoView.Text`

---

#### [4] Dynamic Module Injection  (lines 336–396)

```
PSEUDOCODE: Fetch and execute the selected IR module
  IF global:TargetModule is null: SKIP (exit case)

  CLEAR screen
  Write-Log INFO "Fetching module: <name>"

  FetchUrl = raw GitHub URL for <TargetModule>/Entry.ps1 with cache-buster GUID
  transcriptFile = %TEMP%\toolkit_module_run.log

  TRY:
    ModuleCode  = Invoke-RestMethod FetchUrl (authenticated)
    ScriptBlock = [scriptblock]::Create(ModuleCode)

    STOP any existing transcript (suppress errors — handles already-stopped state)
    START transcript to transcriptFile (Force — overwrites if exists)
    TRY:
      DOT-SOURCE ScriptBlock with -AuthHeader -RepoOwner -RepoName -Branch -AppName
    FINALLY:
      STOP transcript   ← always runs, even if module throws

  CATCH (outer — fetch or scriptblock creation failed):
    STOP any transcript (suppress)
    PRINT error message in Red
    Write-DebugWindow errMsg ERROR

  --- TRANSCRIPT PARSE ---
  global:LastModuleRun    = TargetModule name
  global:LastModuleOutput = null

  IF transcriptFile exists:
    TRY:
      rawLines = read transcriptFile (UTF-8)

      Find startIdx: scan forward for "Transcript started" line → body starts next line
      Find endIdx:   scan backward for "****" line → body ends before it

      IF endIdx > startIdx:
        bodyLines = rawLines[startIdx .. endIdx-1]
        cleaned   = each line with ANSI escape sequences stripped
                    (regex: \x1B\[[0-9;]*[mGKHFABCDsuJnphfABCDR])
        global:LastModuleOutput = join cleaned lines on "\n", trimmed
    CATCH: (silent — output capture failure is non-fatal)
    DELETE transcriptFile

  PRINT "Press [Enter] to return..."
  Read-Host (blocks — gives operator time to read module output)

  global:TargetModule = null
  → loop continues; TUI re-initializes with LastModuleOutput displayed in right pane
```

**Inputs:** `$global:TargetModule`, `$AuthHeader`, `$RepoOwner`, `$TargetRepo`, `$Branch`  
**Outputs:** `$global:LastModuleOutput` (string), `$global:LastModuleRun` (string)  
**Error conditions:** Module fetch fails (401, network error) → logs ERROR, right pane gets whatever partial transcript exists (usually empty). Module crashes mid-run → transcript is stopped in `finally`, partial output is captured and displayed. ANSI codes from `Write-Host -ForegroundColor` are stripped so the right pane TextView renders clean text.

---

## 7. GLOBAL STATE REFERENCE

All globals are set by `Start-Toolkit.cmd` and consumed by `Entry.ps1` (which is dot-sourced into the same scope).

| Variable | Set by | Consumed by | Purpose |
|---|---|---|---|
| `$global:ToolkitAuthHeader` | Options 4 / 7, production auth | `Entry.ps1` param binding | GitHub API Bearer token as hashtable |
| `$global:ToolkitPAT` | Options 4 / 7, production auth | `Entry.ps1` param binding | Raw PAT string (fallback) |
| `$global:ToolkitRepoOwner` | Options 4 / 7, production auth | `Entry.ps1` param binding | GitHub owner for modules repo |
| `$global:ToolkitTargetRepo` | Options 4 / 7, production auth | `Entry.ps1` param binding | GitHub repo name for modules |
| `$global:ToolkitBranch` | Options 4 / 7, production auth | `Entry.ps1` param binding | Git branch for all fetches |
| `$global:ToolkitDebugMode` | Option 7, initialized to `$false` | Production ingestion [5] | If true: load local `Entry.ps1` instead of CDN |
| `$global:DebugSync` | `DebugWindow.psm1` module init, auto-reconnect, `Start-DebugWindow` | `Stop-DebugWindow` | Synchronized hashtable: `{LogFile, Running, WpfProc}` — legacy; `Write-DebugWindow` does not depend on it |
| `$global:Modules` | `Entry.ps1` [2] | `Entry.ps1` [3] TUI, BuildInfoPane | List of module metadata hashtables |
| `$global:MenuLabels` | `Entry.ps1` [2] | `Entry.ps1` [3] ListView | Flat string list for left pane |
| `$global:InfoView` | `Entry.ps1` [3] TUI init | `Entry.ps1` BuildInfoPane, [4] | Terminal.Gui TextView for right pane |
| `$global:BuildInfoPane` | `Entry.ps1` [3] TUI init | Selection event, initial load | Scriptblock that populates right pane |
| `$global:ExitMaster` | `Entry.ps1` init / Exit item handler | `Entry.ps1` while condition | Breaks TUI loop |
| `$global:TargetModule` | `Entry.ps1` item open handler | `Entry.ps1` [4] | Name of module to fetch and run |
| `$global:LastModuleOutput` | `Entry.ps1` [4] transcript parse | `Entry.ps1` [3] initial load | Cleaned transcript for right pane display |
| `$global:LastModuleRun` | `Entry.ps1` [4] | `Entry.ps1` [3] initial load | Module name for right pane title |

---

## 8. TOKEN ENCODING SPECIFICATION

Tokens are stored in `start-toolkit.cfg` using XOR encryption keyed by a PIN + random salt. This is obfuscation, not strong encryption — the goal is to prevent PATs from being readable at a glance from a shared filesystem, not to provide cryptographic security.

**Encoding (Option 2):**
```
Salt      = first 16 characters of NewGuid().ToString("N")   e.g. "a3f9b1c2d4e5f607"
SecretKey = (PIN + Salt).PadRight(32).Substring(0, 32)
KeyBytes  = UTF-16LE bytes of SecretKey                       64 bytes
TokenBytes = UTF-16LE bytes of plain-text PAT
XorResult  = TokenBytes[i] XOR KeyBytes[i mod 64]
Payload    = Base64(XorResult)
Stored     = "<Salt>|<Payload>|<nonce-guid>"
```

**Decoding (Options 4, 7, and production auth):**
```
Split stored value on "|" → [Salt, Payload, Nonce]
SecretKey  = (PIN + Salt).PadRight(32).Substring(0, 32)
KeyBytes   = UTF-16LE bytes of SecretKey
XorResult  = Base64Decode(Payload)
PlainText  = XorResult[i] XOR KeyBytes[i mod 64]
PAT        = UTF-16LE decode, Trim(), Replace(NUL, "")
```

**Wrong PIN behavior:** Decoding with an incorrect PIN produces garbage bytes that decode to a non-PAT string. No error is thrown at decode time; the invalid token is passed to the GitHub API which returns 401. There is no lockout or attempt counter.

**Legacy format (no pipe character):** Raw `Base64(UTF-8 bytes of PAT)` with no XOR. Handled in the `else` branch of `Get-DecodedToken`. No PIN required for this format — any legacy tokens should be re-rolled via Option 2.

---

## 9. ERROR CONDITIONS & RECOVERY PATHS

| Condition | Detection point | Behavior | Recovery |
|---|---|---|---|
| `pwsh.exe` not installed | [1] Engine Handoff | FATAL print + Exit | Install PowerShell 7 |
| `start-toolkit.cfg` missing | Production ingestion [3] | Throws with tip | Boot with Shift → Option 2 to create user |
| Wrong PIN at login | `Get-DecodedToken` → GitHub API 401 | Auth failed message, returns to menu | Retry with correct PIN |
| GitHub API 401 / 404 (bad token) | Entry.ps1 [2] discovery | ERROR log, empty module list | Fix token via Option 2; re-authenticate |
| GitHub API rate limit | Entry.ps1 [2] discovery | ERROR log per request; partial or empty module list | Wait or use authenticated token |
| Module fetch fails (4xx/5xx) | Entry.ps1 [4] | ERROR log, Write-DebugWindow, no module runs, right pane shows whatever transcript exists | Verify repo access, re-authenticate |
| Module crashes mid-run | Entry.ps1 [4] outer catch | CRASH message printed + logged; transcript stopped in `finally`; partial output captured | Operator presses Enter to return to TUI |
| Debug window process dies unexpectedly | `Write-DebugWindow` → `proc.HasExited` | Falls back to `Write-Host` for all subsequent messages | Re-open Option 1; old log file truncated on fresh launch |
| UAC denied / cancelled | Option 6 catch block | Flag file deleted; error message shown | Try again or right-click → Run as administrator |
| Second instance detected | Mutex check | Prompts operator to co-exist or kill old session | Operator choice |
| Terminal.Gui assembly missing or corrupt | Entry.ps1 [1] `LoadFrom` → later type reference | TypeNotFoundException surfaces when TUI initializes | Delete `%TEMP%\TerminalGui_Standalone_Master\` and relaunch |
| `C:\ProgramData\CassenaCareToolkit\` not writable | Any IPC file write | `AppendAllText` / `WriteAllText` throws; Write-DebugWindow falls back to Write-Host | Check directory ACLs; should be auto-created with correct inheritance |
| Transcript already active (e.g., ISE or outer session) | Entry.ps1 [4] `Start-Transcript` | Pre-emptive `Stop-Transcript` runs before `Start-Transcript`; clears state | Handled automatically |
| `TERM` / `COLORTERM` env vars set (WSL, MinTTY) | Entry.ps1 [3] TUI init | Saved, cleared before `Application::Init`, restored after | Handled automatically |
