# DiscourseAdmin.jl: Discourse Config as Code

Discourse has a very simple admin API with each route describing a group of settings, and it's possible to ask for only the _overridden_ ones. This repository stores, syncs, and enables collaboration for these overrides on the [Julia Discourse board](https://discourse.julialang.org).

## Currently supported endpoints

### Site Texts

The [Site Texts feature of Discourse](https://meta.discourse.org/t/customize-text-in-discourse/36092) allows overriding (and optionally translating) pretty much every and any text that appears on the platform. These can range from very short slugs (like date formats) to long form (and crucially critical) community resources like the site guidelines. One special thing about site texts is that they are localized and may have multiple values at a single key.

## How it works

The repository's `admin/` tree mirrors the API routes of the same paths, so supporting another endpoint is a matter of making the directory and a `.gitkeep`. The currently-overriden settings at that endpoint will be populated upon merge to main.

An entry on a locale-less route is simply `admin/route/key.ext`. For a localized route (just `site_texts`) it's `route/key/locale.ext`; `admin/customize/site_texts/guidelines_topic.body/en.md` holds the `en` translation of that key.

Extensions are (currently) only for display on GitHub; the contents of the file are simply plaintext. This may at some point support `json` or `toml` formats for more complicated endpoints.

### Pull from Discourse

The **Pull from Discourse** action mirrors the overrides for every configured route under `admin/` from the Discourse API. It runs on a daily schedule, on demand via manual dispatch, and automatically after every push run (see below). This captures changes made through the admin UI.

### Push to Discourse

The **Push to Discourse** action runs upon commit to `main`. It diffs the pushed range of commits and applies each changed file to the entry its path names (see above), with a deleted file reverting that entry to the Discourse default. Commits made by the above pull action are skipped, since that state already came from Discourse.

Before applying anything, the action verifies that the *pre-merge* state of the repository exactly mirrors the live Discourse state. If an admin has changed something through the UI that hasn't been pulled yet, the action fails.

After every push run on `main` — whether it succeeded or failed — the pull action runs and mirrors the live state back into the repo. The pull following a successful push should be a no-op; a failed or partially-applied one is automatically corrected to the current state by the pull commit, so `main` always converges to the live Discourse state with no manual reverts. The failing change can then be rebased and re-landed.

Pull requests run no part of the push action — the API key only ever runs alongside `main`'s own reviewed code, and a PR's diff *is* the preview of the API calls it will make. All PRs must be carefully reviewed, especially with respect to the values they will expose.

In the future, this should explicitly add guardrails to avoid accidentally pulling confidential settings like API keys into the public repository.
