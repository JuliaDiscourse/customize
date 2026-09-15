# Discourse Config as Code

This site configures, tracks, and enables collaboration for the "Site Texts" overrides on the [Julia Discourse board](https://discourse.julialang.org).

## Site Texts

The [Site Texts feature of Discourse](https://meta.discourse.org/t/customize-text-in-discourse/36092) allows overriding (and optionally translating) pretty much every and any text that appears on the platform.

These can range from very short slugs (like date formats) to long form (and crucially critical) community resources like the site guidelines. The default admin UI is lacking: not only is it only available to admins, but it also doesn't easily expose diffs and tracing (although there are logs). This repository is an experiment in open-sourcing these overrides.

## Other admin settings

Are supported by the same convention — any route under `admin/` can be mirrored — but may be even more dangerous; none are tracked here yet.

## How it works

This repository is itself `DiscourseAdmin.jl`, a Julia package wrapping the Discourse admin API (tested in CI against a mock Discourse server). By convention, the repository's `admin/` tree mirrors the API routes of the same paths, so supporting another endpoint is a matter of `mkdir -p`. An entry on a localized route is `route/key/locale.ext` — `admin/customize/site_texts/guidelines_topic.body/en.md` holds the `en` translation of that key, and the filename's locale is sent as the `locale` parameter (which the site texts API requires); an entry on a locale-less route is simply `route/key.ext`. Extensions are only for display on GitHub. Everything outside `admin/` (like the package itself) is out of the sync's scope. A pair of GitHub actions use the package to keep the repository and the live Discourse configuration in sync in both directions:

### Pull from Discourse

The **Pull from Discourse** action mirrors every configured route under `admin/` from the Discourse API — adding, updating, and removing files so the repo matches the live state — then commits any resulting diff directly to `main` as the GitHub Actions user. It runs on a daily schedule, on demand via manual dispatch, and automatically after every push run (see below). This captures changes made through the admin UI.

### Push to Discourse

The **Push to Discourse** action runs upon commit to `main`. It diffs the pushed range of commits and applies each changed file to the entry its path names (see above), with a deleted file reverting that entry to the Discourse default. Commits made by the pull action are skipped, since that state already came from Discourse.

Before applying anything, the action verifies that the *pre-merge* state of the repository exactly mirrors the live Discourse state. If an admin has changed something through the UI that hasn't been pulled yet, the action fails instead of clobbering that change and the pull job re-syncs `main`; rebase and re-land.

After every push run on `main` — whether it succeeded or failed — the pull action runs and mirrors the live state back into the repo. A successful push makes this a no-op; a failed or partially-applied one is automatically corrected by a follow-up commit, so `main` always converges to the live Discourse state with no manual reverts. The offending change can then be rebased and re-landed.

Because the pull runs after every push, `main`'s tip stays in step with the live state, and each push run simply diffs its own triggering event. Any disagreement between the two — an admin UI edit, a workflow run that got skipped or failed — either trips the drift check (applying nothing) or is converged by the next pull as a visible commit, so the system never needs to track what was applied. Routes are declared by the files present — a bare `.gitkeep` in the route directory suffices — and a localized route is mirrored for every locale the site has entries in, so the first pull populates everything from the live state.

Pull requests run no part of the push action — the API key only ever runs alongside `main`'s own reviewed code, and a PR's diff *is* the preview of the API calls it will make. All PRs must be carefully reviewed.

> **Note:** for the pull action to commit directly to `main`, any branch protection on `main` must allow the GitHub Actions bot to push (or not require pull requests for it).
