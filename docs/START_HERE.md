# Start here — hand this folder to Codex

This package contains an implementation plan, not an app or IPA.

Place the files in the root of the project folder that Codex will work in. In an existing repository, merge the project instructions with the existing `AGENTS.md` instead of overwriting it. Keep `IMPLEMENTATION_PLAN.md` intact as the design baseline; let the task ledger record progress. No global Codex configuration change is required.

## Files

`IMPLEMENTATION_PLAN.md` is the complete architecture, phased implementation specification, acceptance gates, and primary-source index.

`AGENTS.md` is concise project guidance for Codex: security boundaries, implementation discipline, and evidence requirements.

`TASKS.md` is the dependency-ordered execution ledger. All tasks begin as NOT STARTED.

## Paste this into Codex

```text
Build the iPhone app specified in IMPLEMENTATION_PLAN.md. First read the
existing repository instructions, AGENTS.md, IMPLEMENTATION_PLAN.md, and
TASKS.md. Inspect the workspace before changing it and preserve unrelated work.

Use the plan as the approved architecture. I use Windows and already have
SideStore. Do not assume I have a local Mac; prepare the documented macOS/Xcode
build route. Do not claim that a simulator or Windows-only check proves an
iphoneos build, a SideStore install, Face ID behavior, or live website login.

Start with Phase 0: reproducible native project/build infrastructure, a
dummy-data encryption round trip, lifecycle privacy cover, and isolated
WKWebView prototypes for TikTok, X/Twitter, and Instagram. Establish which
build and phone tests are actually available. Then implement the next
unblocked tasks in small working slices, updating TASKS.md and TEST_REPORT.md.
Do not spend the whole session restating the plan.

The calculator sequence is only the discreet entry mechanism. The vault
requires proper cryptographic storage and independent authentication.
Persistent website sessions are separate from vault encryption. Follow the
backup, temporary-file, state-revocation, and privacy requirements exactly;
record any necessary architectural deviation before implementing it.

Use synthetic test data. I will enter my own service credentials and handle
2FA on my phone. Never request my passwords in chat, capture cookies, perform
account actions, publish the project, or incur build-service charges without
my explicit authorization. Leave unavailable device/account tests marked
NOT RUN or BLOCKED and continue independent work.

At each checkpoint report what changed, tests actually executed, remaining
risks, and the next unblocked task. At release, provide the source, reproducible
build scripts, an IPA only if actually built, and evidence-separated test and
compatibility reports. Do not describe untested features as working.
```

## Decisions already made

Use native Swift/SwiftUI plus UIKit/WebKit as needed. Provisionally target iOS 18. The first-release calculator scope includes basic and scientific functions, history, and selected offline unit conversions. Handwritten Math Notes, live currencies, cloud sync, and native social clients are not required in v1.

After first-run setup, cold launch goes to the calculator. An owner-selected numeric sequence plus `=` reveals authentication. Face ID or an independent vault passphrase opens private storage and social tabs. The numeric sequence alone is not a strong encryption secret.

The social tabs navigate official websites. Website login and capabilities must be checked on the actual phone. An external-browser fallback is allowed as a documented compromise, not evidence that embedded login works.

Encrypted backup/restore, immediate background locking, and truthful browser-session privacy disclosures are release requirements. Until device and recovery checks pass, use dummy files rather than irreplaceable private data.
