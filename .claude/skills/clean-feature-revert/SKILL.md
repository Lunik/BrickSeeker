---
name: clean-feature-revert
description: Use when the user asks to revert a recently-added feature in this repo. A plain `git revert` of the feature's commit is not enough if any supporting code was committed earlier/separately - check for and remove orphaned leftovers.
---

# Reverting a feature cleanly

`git revert <commit>` only undoes the diff of that exact commit. In this codebase, feature work
is often split across several commits as it develops (a supporting method added in one commit,
the feature itself wired up in a later one). If you revert only the "main" feature commit, any
plumbing that was committed earlier is left behind, unused and possibly broken (e.g. it calls a
helper that the revert just deleted).

This already happened once: the Home dashboard feature's `fetchUserSetsCount()` was committed in
an earlier, unrelated bug-fix commit (because it was sitting in the working tree at the time),
while the feature itself landed in a later commit. Reverting just the later commit left
`fetchUserSetsCount()` behind, referencing an endpoint path constant the revert had already
deleted — a build break that only showed up after the "revert" was declared done.

## Steps

1. `git revert --no-edit <feature-commit>` for the commit(s) that obviously belong to the
   feature.
2. **Don't stop there.** Search for any remaining references to the feature's types/methods/files
   that the revert didn't touch:
   ```bash
   grep -rn "<FeatureType>\|<distinctiveMethodName>" --include="*.swift" .
   ```
3. For anything still present: check `git log --oneline -- <file>` for that symbol's commit — if
   it predates the feature commit you just reverted, it's a leftover. Remove it by hand (delete
   the method/property and its protocol entry, not just comment it out).
4. Run the `ios-build-test` skill's build+test steps. A clean revert must build — if it doesn't,
   you haven't found everything yet.
5. Commit the cleanup separately from the revert commit, with a message that says *why* it was
   needed (so the next person doesn't assume `git revert` alone was sufficient).
