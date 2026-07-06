# App Review rejection log — BrickSeeker

Append-only record of **real** App Review rejections and what each one taught us. Hard rule #8: after any
rejection the user reports, add a row here; if the rejection is a **new class** of failure not already
covered by a hard rule in `SKILL.md`, add a new hard rule and reference it in the "Prevention rule" column.

## How to add an entry

When the user says "I got rejected" and gives the reason:

1. Add a row to the table below (newest at the top of the data rows).
2. Capture Apple's guideline number and the exact message summary — Apple's wording tells you the real
   trigger, which is often narrower than it first looks.
3. Identify the **root cause** in the code/metadata, not just the symptom.
4. Link the fix (commit/PR/issue).
5. Decide: is this already prevented by an existing hard rule? If yes, note which. If no, **add a new hard
   rule to `SKILL.md`** and name it here.

## Log

| Date | App version | Guideline | Apple's message (summary) | Root cause | Fix (commit/PR/issue) | Prevention rule |
|------|-------------|-----------|---------------------------|------------|-----------------------|-----------------|
| — | — | — | *No rejections recorded yet.* | — | — | — |

## Pre-submission risk register (predictions, not rejections)

Recorded before the first submission so real rejections can be matched against what we expected. Move a row
into the log above (with the real Apple message) if it actually triggers a rejection.

| Predicted trigger | Guideline | Likelihood | Mitigation in place | If it still gets rejected |
|-------------------|-----------|-----------|---------------------|---------------------------|
| App icon / splash evokes LEGO trade dress (red studded bricks) | 5.2.1 | Low | Original artwork, generic brick form | Redesign icon to a fully generic/abstract mark; log it and add a hard rule tightening icon guidance |
| French-only UI flagged as incomplete for non-FR storefronts | 2.1 / metadata | Low-med | Ship FR storefronts first, or add EN localization | Restrict storefronts to francophone, or localize |
| "Data Not Collected" nutrition-label stance challenged | 5.1.1 | Low-med | All transfers are user-initiated to services the user holds accounts with; no developer server | Switch to conservative labels (User ID / Other User Content, linked, App Functionality) and align in-app copy |
| Reviewer cannot exercise the app (no key / no physical box) | 2.1 | Med if notes omitted | Reviewer account + key + manual-entry sample set in Review Notes | Improve notes; add a screen-recording to the submission |
| Residual scraping traffic detected | 5.2.2 / 2.3.1(a) | Should be zero after #104 | Scrapers removed; `strings` gate in checklist | Re-audit the binary; this would mean the removal regressed |
