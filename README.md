# Discourse Config as Code

This site configures, tracks, and enables collaboration for the "Site Texts" overrides on the [Julia Discourse board](https://discourse.julialang.org).

## Site Texts

The [Site Texts feature of Discourse](https://meta.discourse.org/t/customize-text-in-discourse/36092) allows overriding (and optionally translating) pretty much every and any text that appears on the platform.

These can range from very short slugs (like date formats) to long form (and crucially critical) community resources like the site guidelines. The default admin UI is lacking: not only is it only available to admins, but it also doesn't easily expose diffs and tracing (although there are logs). This repository is an experiment in open-sourcing these overrides.

## Other admin settings

Would similarly be possible, but may be even more dangerous and are currently not supported.

## How it works

This repo has a GitHub action that — upon commit to `main` — uses the Discourse API to identify the files that changed in the HEAD commit. GitHub branch restrictions should ensure that only one commit lands at a time. These files are used as the slug names, with their contents as the content of the override.

The GitHub action does not perform the API call in pull requests; it only performs the API call upon commiting to `main`.  All PRs must be carefully reviewed and if the action fails on `main`, then that commit should be reverted.
