# What and why

<!-- What changes, and what problem it solves. If it fixes an issue, link it. -->

## How this was verified

<!--
Not "tests pass" — what did you actually check?

For a health metric, the useful evidence is a measurement, not an assertion:
which real night, which real session, what did the number do before and after.
-->

- [ ] `fvm flutter test` passes
- [ ] `fvm dart analyze lib test` is clean
- [ ] Verified against real data, not only synthetic fixtures

---

## Checklists

Delete the sections that do not apply.

### Touching a health metric

- [ ] The metric lives in **`analytics`**, not `edge/lib/compute` (unless it is pure orchestration)
- [ ] It **abstains** when its inputs are insufficient, rather than substituting a population value
- [ ] The tier (`HIGH` / `ESTIMATE` / absent) reflects what the method can actually support
- [ ] A test pins the **method**, not merely the current output
- [ ] Any published method it implements is cited in the source comment

> If the change alters an existing number, say by how much on real data. A
> health metric that silently shifts is worse than one that is visibly wrong.

### Touching stored data

- [ ] `schemaVersion` bumped, and `_open(version:)` is still bound to it
- [ ] Migration test added or updated
- [ ] `kAlgoVersion` bumped if a derived bundle gained fields — **without it, existing days never recompute and the new field reads as permanently absent**
- [ ] Nothing prunes `raw_archive`

### Touching UI

- [ ] Golden re-rendered and **looked at**: `fvm flutter test test/ui_render_test.dart --update-goldens --run-skipped`
- [ ] Colour carries information rather than decoration
- [ ] Absent data renders as absent, never as zero
- [ ] Uncertainty is visible where it exists

### Touching the coach

- [ ] Data added via a new `v_*` **view**, not by widening the deny-list guard
- [ ] `postChat`'s fail-closed size guard is intact
- [ ] `coach_engine` still appends `tool_calls` **verbatim** (this is what preserves Gemini's `thought_signature` through the agentic loop)

---

## Upstream

- [ ] Changes are in clearly separated files where practical, so rebasing onto upstream stays tractable
- [ ] If this fixes something that is also upstream's bug, consider sending it there too
