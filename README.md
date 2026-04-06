# Tom, Jerry & Big Mamma Production System
##  THE HOUSE

  Autonomous Claude task processing system

    Big Mamma .............. Supervisor (runs the house, bosses everyone)
    Tom the Cat ............ Primary Worker (chases tasks like mice)
    Jerry xN ............... Parallel Workers (sneak through worktrees, specializable)
    Spike the Bulldog ...... QA Enforcer (nobody ships bugs on HIS watch)

  Five bash scripts, a web dashboard, and one glorious household of
  barely-controlled chaos. Self-healing, auto-pushing, parallel-executing,
  and funny about it.

  "If I've told you once, I've told you a THOUSAND times..."
                                                   -- Big Mamma

##  THE CAST (FILES)

  claude-start.sh       Opens the House -- launches everyone in one command.
                        Ctrl+C = Big Mamma kicks everyone out.

  claude-worker.sh      Tom -- reads TASKS.md, pounces on the first
                        pending task, runs Claude Code on it, marks it
                        [q] for QA, repeats.

  claude-supervisor.sh  Big Mamma -- coordinates all workers, deploys
                        up to N Jerrys in git worktrees for independent
                        tasks, commits, pushes, cleans up, bosses everyone.

  claude-qa.sh          Spike -- monitors [q] tasks, sniffs for
                        build/lint/type errors, promotes to [x] on pass,
                        injects fix tasks when he finds a mess.

  claude-stop.sh        Big Mamma says "EVERYBODY OUT!" -- kills all
                        processes and cleans up state files.

  ui.py + ui.html       Web dashboard (Flask). Live status, log streaming,
                        task editing, Jerry specialization controls.

  Start Dashboard.bat   Windows launcher -- opens the dashboard in browser.
  Start Dashboard.command   macOS launcher.

  TASKS.md              The task queue file (auto-created if missing).


  QUICK START


  1. Write your tasks in TASKS.md (see format below)
  2. Run:

     ./claude-start.sh --auto

  That's it. Tom chases tasks, Spike validates, Big Mamma pushes.

  To work on a project in a different directory:

     ./claude-start.sh --auto --location D:/Projects/MyApp

  WEB DASHBOARD

  The dashboard gives you a live browser UI for monitoring and controlling
  the House. Start it with:

     python ui.py                   # or double-click "Start Dashboard.bat"

  Then open http://localhost:5005. Features:

  - Live agent status (Tom, Jerrys, Spike, Big Mamma) with state indicators
  - Task list with counts (pending, running, QA, done, failed)
  - Inline task editor (add/edit tasks without touching TASKS.md by hand)
  - Log streaming with per-character filtering (Big Mamma / Tom / Spike)
  - Jerry specialization dropdowns (change roles on the fly)
  - Start/Stop controls for the House
  - Multi-project support (manage multiple --location instances)
  - Auto-discovers running instances

TASK FILE FORMAT (TASKS.md)

  [ ] This task is pending -- Tom will pounce on it
  [!] This task is in progress -- Tom is chasing it right now (don't edit)
  [q] This task is ready for QA -- Spike needs to inspect it
  [x] This task is done -- Spike approved it
  [-] This task failed (Tom ran into a wall)

  Tasks are processed top-to-bottom. Only the first pending [ ] task runs
  at a time (Tom). Big Mamma may send Jerrys after additional pending
  tasks if they're independent.

  IMPORTANT: Task lines must start with [ ] at column 0. No leading
  whitespace, no bullet prefix (not "- [ ]").

  Example:

    [ ] Add a new GET /api/v1/health endpoint in src/routes/health.ts
        that returns { status: "ok", timestamp: Date.now() }. Register
        the route in src/routes/index.ts.

    [ ] Fix the bug in src/utils/date.ts where formatDate() crashes on
        null input. Add a null check that returns "N/A".

  Tips for good tasks:
  - Be specific: file paths, function names, expected behavior
  - One logical unit of work per task
  - Include enough context that someone unfamiliar could do it
  - Keep tasks independent when possible (allows Jerry parallelism)

  COMMANDS

  ./claude-start.sh                                    Defaults: CWD, TASKS.md
  ./claude-start.sh --auto                             Skip permission prompts
  ./claude-start.sh --location D:/Projects/MyApp       Work in another directory
  ./claude-start.sh --branch wed-dev                   Push to a specific branch
  ./claude-start.sh --tasks TODO.md                    Use a different task file
  ./claude-start.sh --jerries 4                        Spawn 4 parallel Jerry workers
  ./claude-start.sh --jerries 0                        Disable parallel workers
  ./claude-start.sh --main                             Merge to main when done
  ./claude-start.sh --auto --location D:/Projects/MyApp --branch feat --main

  ./claude-stop.sh                                     Big Mamma kicks everyone out
  ./claude-stop.sh --force                             Big Mamma grabs the rolling pin
  ./claude-stop.sh --location D:/Projects/MyApp        Close up a specific house

  You can also run the cast separately in multiple terminals:

    Terminal 1:  ./claude-worker.sh TASKS.md --auto          # Tom
    Terminal 2:  ./claude-qa.sh TASKS.md                     # Spike
    Terminal 3:  ./claude-supervisor.sh wed-dev TASKS.md "" --auto  # Big Mamma

  HOW IT WORKS

  TOM THE CAT (claude-worker.sh)
  ──────────────────────────────────
  1. Scans TASKS.md for the first line starting with [ ]
  2. POUNCES! Marks it [!] (in progress)
  3. Runs: claude -p "task description"
  4. If exit 0 -> marks [q] (ready for QA) "Tom CAUGHT it!"
     If exit != 0 -> marks [-] "*SPLAT* Tom ran into a wall!"
  5. Catches his breath for 2 seconds, then chases the next [ ] task
  6. If no pending tasks, sits by the window looking bored (polls every 10s)
  7. Writes status to .worker-status for Big Mamma's awareness

  JERRY xN (spawned by Big Mamma)
  ────────────────────────────────────
  Big Mamma analyzes pending tasks for independence. When Tom is busy
  and 2+ tasks are pending, she asks Claude to identify tasks that can
  safely run in parallel (different files/features, no dependencies).

  Jerry count is configurable with --jerries N (default: 2). Each Jerry
  runs in its own git worktree (isolated hideout). This means up to N+1
  tasks execute at once: 1 Tom + N Jerrys.

  JERRY SPECIALIZATIONS

  Each Jerry can be assigned a role that influences which tasks it picks
  up and what system prompt it receives:

    fullstack (default) .. General-purpose, no preference
    architect ............ System design, project structure, patterns
    backend .............. APIs, services, server logic, middleware
    frontend ............. UI, components, styling, layout
    data ................. Data models, DB schemas, migrations, queries
    platform ............. CI/CD, Docker, infra, deployment
    qa ................... Tests, coverage, edge cases
    design ............... Design tokens, theming, UI patterns

  Specializations are set via the web dashboard dropdown or by writing
  .house-jerry-specs.json (slot-to-role mapping). When tasks are queued:

  1. Pass 1: Specialized Jerrys get tasks matching their keywords first
  2. Pass 2: Remaining free slots fill with any unassigned task

  When a Jerry finishes:
  - Success -> Big Mamma merges the worktree branch, marks task [q]
  - Merge conflict -> "Same old story..." task re-queued for Tom
  - Failure -> Jerry "got caught in a mousetrap!" task re-queued

  Jerrys are instructed to edit files only (no builds or installs)
  since Spike validates everything after merge.

  BIG MAMMA (claude-supervisor.sh)
  ─────────────────────────────────
  1. Every 15 seconds, counts completed tasks in TASKS.md
  2. If new [q] tasks detected:
     a. Debounces 30 seconds ("Hold your horses...")
     b. Stages, commits locally ("Packaging up the work...")
     c. Waits for Spike's verdict before pushing
  3. Manages the Jerrys (spawn, monitor, merge, cleanup)
  4. Detects stale tasks ("THOMAS! Did you fall ASLEEP?!")
  5. After Spike validates ([q] -> [x]), tidies the task list
  6. If Spike is not running, auto-promotes [q] -> [x]
  7. If all tasks done, sends Tom to sleep ("I got my EYE on you")
  8. Optionally merges to main ("Moving this to the MAIN STAGE!")

  SPIKE THE BULLDOG (claude-qa.sh)
  ────────────────────────────────
  Monitors TASKS.md for [q] (QA-ready) tasks. When detected:

  1. Waits for Tom and Jerrys to finish (sits by the door, one eye open)
  2. Runs validation checks (*sniff sniff*):
     - Spike uses Claude to auto-detect your tech stack and run the
       appropriate build, compile, lint, and type-check commands
     - Works for ANY project: TypeScript, Python, Rust, Go, C#, etc.
  3. If ALL pass -> *happy bark* "ALL CLEAR!" promotes [q] -> [x]
     -> Big Mamma pushes and cleans up
  4. If ANY fail -> *GRRR* "CLEAN. THIS. UP. NOW."
     -> injects [AUTO-FIX] task -> Tom picks it up -> Spike re-checks
  5. After 3 failed fix attempts -> *exhausted sigh* "Fine. Ship it."

  This creates a self-healing loop: Tom does task -> marks [q] ->
  Spike inspects -> if broken, Spike sends Tom back to fix ->
  all without human intervention.

  TASK CLEANUP (after Spike's approval)
  ──────────────────────────────────────
  When Spike promotes [q] -> [x], Big Mamma removes completed tasks
  from TASKS.md to keep the house clean. Safety fence: Spike writes
  VALIDATED_DONE=N (the exact count of done tasks at check time).
  Big Mamma only removes up to N lines. Any tasks that completed
  AFTER Spike started checking are left for the next inspection.

  Cleanup only runs when no workers are active (no line-number references
  would be invalidated).

  HIBERNATION (Tom's nap time)
  ─────────────────────────────
  When all tasks are done (no [ ] or [!] in TASKS.md), Big Mamma
  puts Tom to sleep via a .worker-hibernate signal file.

  While hibernating:
  - Tom does NOT call Claude -- zero token usage
  - Tom checks the signal file every 30 seconds (dreaming of mice)
  - Big Mamma keeps polling TASKS.md every 15 seconds (she never rests)

  Tom wakes up automatically when:
  - You add new [ ] tasks to TASKS.md (Big Mamma yells "GET UP!")
  - Spike injects an [AUTO-FIX] task
  - Big Mamma exits or crashes (cleanup trap removes signal file)

  Leave the system running indefinitely -- it costs nothing while idle.

  STALE TASK RECOVERY ("THOMAS!!")
  ────────────────────────────────
  If Tom crashes mid-task, tasks get stuck at [!]. Big Mamma
  detects this via process liveness checks:

  1. Reads .worker-status to find Tom and Claude PIDs
  2. Checks if those PIDs are alive (cross-platform: kill -0 + ps fallback)
  3. After 16 idle cycles (~4 minutes): "THOMAS! You fell ASLEEP?!"
  4. Resets stuck [!] tasks back to [ ] (except Jerry's tasks)
  5. Yells at Tom to wake up if hibernating

================================================================================
  --location: PORTABLE USAGE
================================================================================

  The scripts can live at a fixed location (e.g., D:/ root) and be pointed
  at any project directory:

    D:/claude-start.sh --auto --location D:/Documents/MyProject

  What happens:
  1. Scripts resolve their own directory (SCRIPT_DIR)
  2. cd to the --location directory
  3. Create TASKS.md if it doesn't exist (with template)
  4. Check that it's a git repository
  5. Launch all cast members using absolute paths to SCRIPT_DIR
  6. All logs, status files, locks are created in the project directory

  Path normalization handles Windows quirks (backslashes, double slashes).

  Closing from anywhere:

    D:/claude-stop.sh --location D:/Documents/MyProject

  INTER-PROCESS COMMUNICATION


  The household uses file-based IPC (no sockets, no pipes -- we keep it
  old school, like a cartoon):

  .worker-status         Tom's state: idle/running/hibernating,
                         PIDs, current task, timestamps
  .parallel-status-N     Jerry #N's state (includes SPEC= field)
  .qa-status             Spike's state: idle/checking/passed/failed,
                         VALIDATED_DONE count, error details
  .worker-hibernate      Signal file: exists = Tom should nap
  .claude-worker.pid     Claude process PID (for liveness checks)
  .claude-start.lock     Prevents two houses from opening at once
  .tasks.lock/           Directory-based mutex for TASKS.md edits
  .house-jerries         Jerry slot count (written by claude-start.sh)
  .house-jerry-specs.json  Jerry specialization mapping (slot -> role)

  All status files are auto-cleaned on shutdown.


  LOGS

  claude-worker.log              Tom's diary (structured, concise)
  claude-worker-output.log       Tom's full Claude output (verbose)
  claude-supervisor.log          Big Mamma's ledger
  claude-supervisor-verbose.log  Git command output (verbose)
  claude-qa.log                  Spike's patrol report
  claude-parallel-N.log          Jerry #N Claude output

  When using claude-start.sh, the three main logs stream live to terminal.
  Task descriptions longer than 10 words are truncated with (...) in logs.

  SAFETY
  
  - Will NOT push to main or master ("Big Mamma didn't raise no fool")
  - Debounces commits so rapid completions batch together
  - Never interrupts Tom mid-task
  - Spike validates [q] tasks before they become [x] -- self-heals up to 3 times
  - Only cleans tasks that Spike has validated (VALIDATED_DONE fence)
  - If Spike is offline, Big Mamma auto-promotes [q] -> [x] with a warning
  - Line-number safety: no cleanup while workers hold task references
  - Jerrys use git worktrees (isolated hideouts, no file conflicts)
  - Merge conflicts -> task re-queued for sequential, no data loss
  - Hibernates when idle -- zero API token usage
  - Pull --rebase on push conflicts, with force-with-lease fallback
  - Cross-platform process management (Windows/MSYS taskkill fallback)
  - Ctrl+C kills all processes cleanly via trap handlers
  - Duplicate instance protection via lock file

  ADDING TASKS WHILE RUNNING

  You can edit TASKS.md while the House is running. Just add new [ ] lines
  at the bottom. Tom will pounce on them on his next cycle. You can also
  use the web dashboard's task editor.

  Do NOT edit lines marked [!] -- Tom or a Jerry is actively chasing those.

  STOPPING

  If running via claude-start.sh:   Ctrl+C (Big Mamma: "EVERYBODY OUT!")

  From anywhere:                    ./claude-stop.sh
                                    ./claude-stop.sh --location D:/Projects/App
                                    ./claude-stop.sh --force


  TROUBLESHOOTING

  Problem: Tom marks task [-] failed (*SPLAT*)
  Fix:     Check claude-worker.log for details. Rewrite the task to be
           clearer, change [-] back to [ ], save. Tom will try again.

  Problem: Big Mamma can't push ("Can't get this out the door no-HOW")
  Fix:     Check claude-supervisor.log and claude-supervisor-verbose.log.
           Usually means remote has new commits. Pull manually, resolve
           conflicts, then restart.

  Problem: "Not a git repository"
  Fix:     Run from the repo root, or use --location to point at a repo.

  Problem: Tasks not being picked up
  Fix:     Make sure the line starts with exactly [ ] (space inside
           brackets). No leading whitespace, no "- [ ]" prefix.

  Problem: Jerrys keep getting merge conflicts ("Same old story...")
  Fix:     Tasks may not be truly independent. Make them touch different
           files/directories. The system auto-falls-back to sequential.

  Problem: kill doesn't work on Windows (MSYS/Git Bash)
  Fix:     The scripts use taskkill via /proc/<pid>/winpid as fallback.
           If still stuck: taskkill //F //PID <pid> manually.

  Problem: Spike keeps failing on the same error
  Fix:     After 3 fix attempts, Spike gives up ("I'm too old for this")
           and allows push with warnings. Check claude-qa.log.

  Problem: Tasks stuck at [q] and never promoted
  Fix:     Spike may not be running. Big Mamma will auto-promote [q] -> [x]
           if she detects Spike is offline, but only after all workers idle.


  CAST CREDITS


  Inspired by the classic Tom & Jerry cartoons.

  Tom never catches Jerry. Jerry always outsmarts Tom.
  Big Mamma keeps the house running despite the chaos.
  Spike just wants everyone to follow the rules.

  ...but together, they ship code. Somehow.
