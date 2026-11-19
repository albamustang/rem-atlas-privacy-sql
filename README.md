# REM Atlas: the privacy layer

REM Atlas ([rematlas.app](https://rematlas.app)) is a world map of dreams. People log what they
dreamed, where and when, and the site shows patterns across places and nights. Dreams are personal,
so the site makes promises about who can see what. This repository is the database code that keeps
those promises, published so you can check them instead of taking our word for it.

It is the complete set of Postgres migrations (Supabase) the live site runs, in order, with one
redaction noted below. The rest of the application is not published.

## The promises, and where to check them

| Promise | Where it's enforced |
|---|---|
| Nobody can read anyone else's dreams, nights or answers. Row-level security is on every personal table. | `0001_init.sql`, and every later migration that adds a table |
| A private dream never leaves the database as a row, only as part of a count. | `0029_privacy_floor.sql` (the `public_dreams` view lists public dreams only) |
| A place or keyword appears on the map only once **3 different people** have logged it. Quieter cities are merged into their country, or left off. | `atlas_counts()` in `0029_privacy_floor.sql`, lift colouring in `0034_atlas_keyword_lift.sql` |
| Timeline totals and the "at a glance" summary follow the same floor (summaries need 30+ dreams from 5+ people). | `atlas_nights()` and `atlas_summary()` in `0030_atlas_timeline_summary.sql` |
| Personal comparisons need **30+ dreams from 5+ people**, and a city is only shown if the rest of its country can't be subtracted to single someone out. | `profile_comparison()` in `0029_privacy_floor.sql` |
| Research downloads are counts only, groups of 10+ dreams from 3+ people, never text. | `research_counts()` in `0029_privacy_floor.sql` (updated in `0038_one_plan.sql`) |
| Specific violent or self-harm words are shown only under a neutral umbrella ("violence", "conflict", "distress"), because on a small site a specific word could identify someone. | `0025_sensitive_keyword_umbrellas.sql` |
| The public copy of a dream can only ever be the original with characters masked; it can't be rewritten. | `0005_explicit_filter.sql` |
| Every time a site admin opens someone's dream, comment or profile text, it is logged, and the person can read that log. Rows can't be edited or deleted. | `0061_admin_access_log.sql` |
| Deleting your account deletes everything you logged. | `0004_delete_my_account.sql` and the `on delete cascade` keys throughout |
| In the online experiments ([REM Labs](https://rematlas.app/experiments)), the random draw is made by the database, with `gen_random_bytes`, after you've committed your answer, so nobody can nudge it. | `0057_picture_test.sql`, `0063_recall_test.sql`, `0064_bedtime_list_test.sql` |

Each experiment's method was registered publicly before it opened:
[Tomorrow's picture](https://osf.io/ybt96), [Remember more](https://osf.io/2ph7q),
[Lists before bed](https://osf.io/4dzpa).

## What's left out

One thing is withheld: the word list in the explicit-content filter (in `0005_explicit_filter.sql`
and `0008_profiles.sql`). Published, it would be a list of ways round it. The rule that uses it is
shown in full; only the words are replaced by `withheld`.

The application code (the website itself) is not published. That includes the AI screening of text
people choose to make public, and the moderation tools.

## Known limits

We'd rather you heard these from us:

- Comparing many overlapping date windows on the map could in principle reveal small differences
  between them. If the dataset grows large enough to make that useful, the plan is to add
  statistical noise (differential privacy).
- Dream text and keywords are stored readable by the database, on encrypted disks, not end-to-end
  encrypted. [Who can read my dreams?](https://rematlas.app/dream-privacy) explains exactly who can,
  and why.

## Found a problem?

Please tell us privately first: [rematlas.app/security](https://rematlas.app/security).

## Licence

GNU Affero General Public License v3.0 (see `LICENSE`). If you run a modified version of this code
as a service, you have to publish your changes too.

REM Atlas is developed and published by Promethean Ventures Ltd (SC908147), Scotland.
