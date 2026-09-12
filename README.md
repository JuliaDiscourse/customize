# Discourse Config as Code

This site configures, tracks, and enables collaboration for the "Site Texts" overrides on the [Julia Discourse board](https://discourse.julialang.org).

## Site Texts

The [Site Texts feature of Discourse](https://meta.discourse.org/t/customize-text-in-discourse/36092) allows overriding (and optionally translating) pretty much every and any text that appears on the platform.

These can range from very short slugs (like date formats) to long form (and crucially critical) community resources like the site guidelines. The default admin UI is lacking: not only is it only available to admins, but it also doesn't easily expose diffs and tracing (although there are logs). This repository is an experiment in open-sourcing these overrides.

## Other admin settings

Would similarly be possible, but may be even more dangerous and are currently not supported.

## How it works

The sync logic lives in [`DiscourseAdmin.jl`](DiscourseAdmin/), a Julia package wrapping the Discourse admin API (tested in CI against a mock Discourse server). By convention, the repository's `admin/` tree mirrors the API routes of the same paths, so supporting another endpoint is a matter of `mkdir -p`. An entry on a localized route is `route/key/locale.ext` — `admin/customize/site_texts/guidelines_topic.body/en.md` holds the `en` translation of that key, and the filename's locale is sent as the `locale` parameter (which the site texts API requires); an entry on a locale-less route is simply `route/key.ext`. Extensions are only for display on GitHub. Everything outside `admin/` (like the package itself) is out of the sync's scope. A pair of GitHub actions use the package to keep the repository and the live Discourse configuration in sync in both directions:

### Pull from Discourse

The **Pull from Discourse** action fetches all currently-overridden site texts from the Discourse API and mirrors them into `admin/customize/site_texts/` — adding, updating, and removing files so the repo matches the live state — then commits any resulting diff directly to `main` as the GitHub Actions user. It runs on a daily schedule, on demand via manual dispatch, and automatically after every push run (see below). This captures changes made through the admin UI.

### Push to Discourse

The **Push to Discourse** action runs upon commit to `main`. It diffs the pushed range of commits and applies those changes to Discourse: each changed file's basename is used as the site text key with its contents as the override value, and a deleted file reverts that override to the Discourse default. Commits made by the pull action are skipped, since that state already came from Discourse.

Before applying anything, the action verifies that the *pre-merge* state of the repository exactly mirrors the live Discourse state. If an admin has changed something through the UI that hasn't been pulled yet, the action fails instead of clobbering that change. This check also runs in the PR dry run (when secrets are available; PRs from forks skip it), so drift is surfaced before merging; making the PR check a required status check in the branch protection settings enforces this.

After every push run on `main` — whether it succeeded or failed — the pull action runs and mirrors the live state back into the repo. A successful push makes this a no-op; a failed or partially-applied one is automatically corrected by a follow-up commit, so `main` always converges to the live Discourse state with no manual reverts. The offending change can then be rebased and re-landed.

Because the pull runs after every push, `main`'s tip stays in step with the live state, and each push run simply diffs its own triggering event. Any disagreement between the two — an admin UI edit, a workflow run that got skipped or failed — either trips the drift check (applying nothing) or is converged by the next pull as a visible commit, so the system never needs to track what was applied. Routes are declared by the files present — a bare `.gitkeep` in the route directory suffices — and a localized route is mirrored for every locale the site has entries in, so the first pull populates everything from the live state.

The push action does not perform any config-changing API calls in pull requests; it only prints a dry run of what would happen. All PRs must still be carefully reviewed.

> **Note:** for the pull action to commit directly to `main`, any branch protection on `main` must allow the GitHub Actions bot to push (or not require pull requests for it).
