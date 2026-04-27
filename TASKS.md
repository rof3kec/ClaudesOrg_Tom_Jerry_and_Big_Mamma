# Claude Task Queue

Tasks are processed top-to-bottom.
- `[ ]` = pending
- `[!]` = in progress (do not edit)
- `[q]` = ready for QA (do not edit)
- `[x]` = done
- `[-]` = failed

## Mamma Instructions

This is a bash-based AI task orchestration system with smart dispatch capabilities.
Frontend uses bash scripts, backend is supervisor logic.
Key files: lib/house-*.sh, claude-supervisor.sh, claude-worker.sh

__________________________________________________________________________

[ ] Add input validation to the analyze_task_batch function in lib/house-dispatch.sh
    Ensure section_name is not empty and TASK_FILE exists before processing

[ ] Create unit tests for can_parallelize_with function
    Test cases: solo tasks, conflict clusters, same cluster, different clusters

[ ] Refactor the conflict detection algorithm in detect_conflict_clusters
    Optimize the nested loops to reduce O(n²) complexity for large task sets

[ ] Add logging for cache hits/misses in load_dispatch_cache
    Track when cache is used vs fresh analysis to measure performance

[ ] Update simulate-dispatch.sh to support JSON output format
    Add --json flag that outputs results in machine-readable format

[ ] Fix edge case in fill_jerry_slots where empty CAND_LINES causes error
    Add bounds checking before accessing array elements

[ ] Implement fallback_analysis timeout handling
    If analysis takes >60s, return conservative estimates immediately

[ ] Add metrics collection to house-common.sh
    Track: task completion times, worker utilization, conflict rate

[ ] Create visualization script for .house-dispatch-cache
    Generate ASCII art dependency graph showing conflict clusters

[ ] Optimize files_overlap function to use hash tables
    Current string iteration is slow for tasks with many files

[ ] Add support for manual task hints in TASKS.md
    Allow users to specify [HEAVY] or [LIGHT] tags to override analysis

[ ] Implement cache invalidation based on file modification times
    Clear cache if any source files changed since last analysis
