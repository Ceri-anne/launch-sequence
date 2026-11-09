---
name: setup-launchseq
description: Set up an iOS app repo to release with launchseq (countdown and liftoff), whether it's the first app on this Mac or another one. Use when asked to add launchseq, a .launchseq.yml, or the launch-sequence release flow to a repo.
---

# Set up launchseq in an app repo

The goal is a repo where `launchseq doctor` reports **Ready**, plus a short list of the manual steps that only the person can do. `launchseq --help` and the [launch-sequence README](https://github.com/Ceri-anne/launch-sequence#readme) are the reference for every command and config key. This skill covers the decisions they leave to you.

Work on a branch, and end with a PR. Every step has **Done when**: finish it before you move on.

## 1. Find what's already in place

This decides how much of the rest you do. A second or third app on the same Mac usually has the tool and credentials already.

- `launchseq --version`. If it isn't found, install it as the README says. Before copying the binary anywhere, run `echo $PATH` and pick a folder on it that the person can write to. `~/bin` often isn't on PATH.
- `launchseq init --help`. If there's no `init` subcommand, the installed launchseq is older than the README, so rebuild it from a fresh clone.
- Credentials: `ASC_KEY_ID` in the environment, or `~/.config/launchseq/credentials`. One App Store Connect key works for every app on the account, so a later repo reuses the file as it is.
- The app repo's release habits: an archive or upload script, a screenshot capture script, App Store copy in Markdown, an `AGENTS.md`/`CLAUDE.md`, and the website or repo that hosts the support and privacy pages.

**Done when** you can say, for each of the five steps below, whether it's needed.

## 2. Draft the config

Run `launchseq init --dry-run`, read the draft and its warnings, then run `launchseq init`. Then correct what init can't know:

- **languages**: one entry for each language the app ships, not just the App Store listings. Get them from `Localizable.xcstrings` (or the `.lproj` folders) and from the locales the listing already has in App Store Connect. A language the App Store has no listing for (Welsh, for example) gets no `asc_locale`. Set `app_store.primary_locale` to the listing's real primary locale. init assumes `en-US`, which is often wrong outside the US.
- **test.simulator**: if CI runs snapshot tests, use CI's exact device and OS, not the newest one. The repo's agent docs or CI config usually say which. Ask if they don't.
- **test.scheme**: confirm it against `xcodebuild -list` when init had to guess.
- **screenshots**: fill this in only if the app can already open on a fixed screen from a launch argument. If there's a capture script, copy its scenes, devices, status bar settings and per-device language subsets into this section. If there isn't, leave the section out and say so in the hand-off. Adding a screenshot hook to the app is a separate change.
- **website**: fill this in if the support, privacy or accessibility pages are on a site launchseq can open PRs against.
- **privacy_sensitive_paths**: the code that decides what data the app stores, syncs or sends, plus entitlements and `Info.plist`.

**Done when** `launchseq doctor --offline` has no config errors. Missing copy is fine at this point, because that's step 3.

## 3. Move the App Store copy into metadata files

launchseq uploads `<metadata_dir>/<asc-locale>/*.txt`, one file per field.

- **Markdown copy exists**: `launchseq migrate-copy --dry-run FILE:LANG ... --support-url ... --privacy-url ...`, then without `--dry-run`. Get the URLs from the live listing or the repo, not by guessing. Spot-check a few files against the Markdown, including one non-English locale.
- **No copy in the repo**: ask the person for the current listing text, or have them export it from App Store Connect, and write the files. Leave out `release_notes.txt`, because countdown drafts it.

**Done when** doctor reports the copy as valid for every `asc_locale`.

## 4. Settle each source of truth

Setting up launchseq moves things into the repo. Anything still kept somewhere else will drift.

- **Website pages**: when `website` is set, `website.source` in the app repo becomes the source and liftoff overwrites the site's copy. Copy the current pages in from the site repo unchanged (`gh api repos/<repo>/contents/<folder>/<page> -H 'Accept: application/vnd.github.raw'`). Check that assets referenced by root-relative paths still live on the site. Any doc that said "edit these pages in the site repo" now needs to say the opposite.
- **Old copy files**: if scripts still read the Markdown copy, keep it, and record that the `metadata/` files are what ship. Retiring the Markdown is a separate change.
- **Agent docs** (`AGENTS.md`/`CLAUDE.md`): add a release section. It should say that `countdown` and `liftoff` push and publish, so an agent asks before running them. It should say where listing text and the website pages are now edited, and that adding a language means a `languages` entry and a metadata folder. Keep it to what the repo can't tell an agent by itself.

**Done when** every listing field and website page has exactly one place to edit it, and the agent docs name that place.

## 5. Credentials

Skip this if step 1 found them. Otherwise reuse the key the repo already signs with: an archive script often has the key ID, issuer ID and `.p8` path as defaults. Write `~/.config/launchseq/credentials` with `umask 077`, then `chmod 600`. It holds the IDs and the key's path, never the key's contents. Leave the `.p8` where it is, and keep it out of the repo and out of chat.

**Done when** `launchseq doctor` (online) reports that the key loaded and the app was found.

## 6. Hand off

Run `launchseq doctor`. Commit on the branch and open a PR. The PR body lists what was migrated, and what was left for a separate change.

Then tell the person what only they can do:

- In App Store Connect, the Xcode Cloud **Release** workflow's start condition must be a tag change matching `*.*.*`.
- `ANTHROPIC_API_KEY` translates release notes. Without it, countdown stops at `TODO` placeholders that have to be translated by hand.
- Any screenshot hook, script change or copy retirement you deliberately left out.

**Done when** doctor reports **Ready**, the PR is open, and every remaining doctor warning is either fixed or named in the hand-off with its reason.
