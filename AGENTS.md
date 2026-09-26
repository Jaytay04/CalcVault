# CalcVault project rules

Read `docs/IMPLEMENTATION_PLAN.md` before changing the project; it is the full specification. Work only on the current phase, preserve existing work, and record evidence in `docs/TASKS.md` and `docs/TEST_REPORT.md`.

- Ship one app. Keep the recovery/install-check identity as the only additional App ID; do not add extensions or more products without review.
- The user-selected independent archive is authoritative. Missing, stale, unreadable, or corrupt data must fail visibly and must never create an empty replacement.
- Plain TAR is packaging/concealment, not encryption. Never describe it as encrypted storage.
- Never delete the only valid archive, automatically delete Photos originals, or make destructive device changes without explicit approval.
- Keep calculator, vault, and social boundaries separate. No unofficial social APIs, credential capture, cookie copying, or JavaScript-to-native vault/filesystem access.
- Keep account credentials, signing material, and real private media out of source, fixtures, logs, and screenshots. Use disposable synthetic fixtures.
- Ask before destructive device actions or paid infrastructure. Never claim a build, IPA, install, device test, biometric result, or live-login result unless it actually ran.
