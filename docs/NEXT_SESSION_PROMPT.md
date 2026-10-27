# Prompt for a fresh Claude Code session

Paste this into a new Claude Code session opened in the iBoard repo:

> You are continuing iBoard. Read `CLAUDE.md`, `ROADMAP.md` §1–§6 and the newest §15 entries, then `docs/HANDOFF.md` (§9 is the latest).
> The owner granted full autonomy to complete the roadmap and make the app production ready; they handle only Apple-account steps
> (see `docs/RELEASE_CHECKLIST.md`). Run `scripts/install-hooks.sh`. Work the open items in HANDOFF §9 and every `[~]` task in ROADMAP §9
> toward `[x]` using parallel worktree agents with disjoint file ownership (agents write `docs/agent-reports/*.md`; you merge branches and update the
> roadmap yourself). Verify with `scripts/build.sh` and `scripts/test.sh --no-ui`; install on the owner's iPhone 12 per HANDOFF §9 when keyboard
> changes need a device check, and ask the owner to test only what cannot be automated. Keep statuses honest (`[~]` until verified on a device).
