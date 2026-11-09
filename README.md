# Launch Sequence

`launchseq` releases an iOS app in two stages:

```text
launchseq countdown   tests → version bump → App Store screenshots → release notes → release PR
launchseq liftoff     CI gate → tag → Xcode Cloud build → website pages → App Store Connect
```

Liftoff stops once the App Store version is ready. You check it in App Store Connect and press **Submit for Review** yourself.

It's built for apps that:

- build in **Xcode Cloud**, with a workflow that starts when a tag is pushed and distributes to TestFlight
- keep their App Store copy in the repo as plain text files
- can open on a given screen from a launch argument, so screenshots are taken from fixed states instead of by playing the app

Each app describes itself in a `.launchseq.yml`. There's nothing app-specific in the tool.

## Install

Install a tagged [release](https://github.com/Ceri-anne/launch-sequence/releases), not `main`. `launchseq` pushes tags and edits your App Store Connect versions, so pin a version you've read the notes for. The examples below use `0.1.0`; swap in the latest release.

```bash
git clone --branch 0.1.0 --depth 1 https://github.com/Ceri-anne/launch-sequence.git
cd launch-sequence
swift build -c release
cp .build/release/launchseq /usr/local/bin/
```

Any folder on your `PATH` works. Check with `echo $PATH`: a fresh Mac often has no `~/bin`, `/usr/local/bin` may need `sudo` or not exist yet, and on Apple silicon with Homebrew, `/opt/homebrew/bin` is already on it and yours to write to. Run `launchseq --version` to confirm.

If you use [Mint](https://github.com/yonaskolb/Mint), it does the same build for you:

```bash
mint install Ceri-anne/launch-sequence@0.1.0
```

To upgrade, read the new release's notes, then repeat either install with the new tag.

You'll need Xcode, `git`, and the [GitHub CLI](https://cli.github.com) signed in (`gh auth login`).

## Credentials

The App Store Connect API key is read from the first place it's found:

1. The environment: `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_PATH` (the path to `AuthKey_<id>.p8`) or `ASC_KEY_P8` (the key's contents).
2. `~/.config/launchseq/credentials`. It must be `chmod 600`, and launchseq refuses to read it otherwise.

   ```ini
   key_id = ABC123DEF4
   issuer_id = 00000000-0000-0000-0000-000000000000
   key_path = ~/.secrets/AppStoreConnect/AuthKey_ABC123DEF4.p8
   ```

3. For the private key only, the login Keychain:

   ```bash
   security add-generic-password -s launchseq -a ABC123DEF4 -w "$(cat AuthKey_ABC123DEF4.p8)"
   ```

The key needs the **Admin** role if Xcode Cloud has to create signing certificates. App Manager is enough for everything launchseq itself does.

To have release notes translated, set `ANTHROPIC_API_KEY`. Without it, the other locales get `TODO` stubs, and countdown won't continue until they're filled in.

## Setting up an app

With [Claude Code](https://claude.com/claude-code), the `setup-launchseq` skill walks through the steps below. It also covers the choices they leave open: which languages to list, which simulator to pin, and where the website pages and listing text get edited from now on. Install it once:

```bash
claude plugin marketplace add Ceri-anne/launch-sequence
claude plugin install launchseq@launch-sequence
```

Then, in the app's repo, ask Claude to set it up with launchseq.

By hand:

1. Run `launchseq init` in the app's repo. It drafts `.launchseq.yml` from the project (or XcodeGen's `project.yml`), the file holding `MARKETING_VERSION`, the bundle ID and the newest iPhone Pro simulator, and lists anything it had to guess. Add your languages, and the optional sections you use. [`examples/launchseq.yml`](examples/launchseq.yml) is a complete config to copy from. `launchseq init --dry-run` prints the draft without writing it.
2. Move the App Store copy into `<metadata_dir>/<asc-locale>/`, one file per field:

   ```text
   AppStoreAssets/metadata/
     support_url.txt          shared by every locale (a locale folder can override it)
     privacy_url.txt
     marketing_url.txt
     en-GB/name.txt           max 30
     en-GB/subtitle.txt       max 30
     en-GB/promotional_text.txt  max 170
     en-GB/keywords.txt       max 100, comma-separated, no spaces after commas
     en-GB/description.txt    max 4000
     en-GB/release_notes.txt  max 4000, "What's New"
   ```

   If the copy lives in Markdown with headings like `### Subtitle (max 30)` and a fenced block under each, `launchseq migrate-copy Copy.md:en Copy-Localized.md` converts it. It leaves out "What's New", because that belongs to one release: the next countdown drafts it.
3. Put the support, privacy and accessibility pages in the folder `website.source` names. That folder is the source, and the website copy is the output.
4. In App Store Connect, make sure the Xcode Cloud **Release** workflow's start condition is a tag change matching `*.*.*`.
5. Run `launchseq doctor`.

## Countdown

```bash
launchseq countdown                     # minor bump: 1.1.0 → 1.2.0
launchseq countdown --bump patch        # or major
launchseq countdown --set-version 2.0.0
launchseq countdown --dry-run           # show the plan, change nothing
```

1. Checks that the tree is clean, then fetches. The **latest `X.Y.Z` tag is the source of truth** for the current version, and other tag shapes are ignored. If `MARKETING_VERSION` is already ahead of the bumped tag, the larger version is used.
2. Checks the App Store copy against Apple's limits before anything slow runs.
3. Creates `release/<version>` from `origin/main`.
4. Runs the test suite on the simulator from the config. It needs an exact OS version, because several runtimes can share a device name.
5. Bumps `MARKETING_VERSION` everywhere it appears in `version.file`.
6. Builds Debug apps and captures every language × device × scene. If a device has a `before:` step (such as unfolding a simulator in Device Hub), countdown waits for you. Then it runs the app's `render` hook and checks every rendered image against the slot's accepted pixel sizes.
7. Drafts English release notes from the commit subjects since the last tag and opens them in `$EDITOR`. Once you've saved them, Claude translates them into each other locale, using that locale's description as a guide to tone. Countdown refuses to ship notes that haven't changed since the last release, unless you pass `--reuse-notes`.
8. Warns if files matching `privacy_sensitive_paths` changed but the website pages didn't.
9. Commits and opens a release PR. Review the screenshots and translations there, then **Rebase and merge**. `--direct` pushes to the base branch instead.

Progress is saved in `.git/launchseq/state.json`, so a re-run skips the steps that are already done. `--fresh` starts over.

## Liftoff

Run this on an up-to-date `main` after the release PR has merged:

```bash
git switch main && git pull --rebase
launchseq liftoff --dry-run    # reads App Store Connect, changes nothing
launchseq liftoff
```

1. Reads the version from `main`, and checks the copy and screenshots.
2. Requires green CI checks (Xcode Cloud reports them to GitHub) on the release commit. `--force` overrides this.
3. After confirming with you, pushes an annotated tag, which starts the Xcode Cloud Release build. It also creates a **draft** GitHub release.
4. Copies the website pages into a temporary clone of the site repo and, if they've changed, opens a PR. It waits for the PR's checks and asks before merging.
5. In App Store Connect: creates or reuses the version, sets the release type and phased release, and updates the name, subtitle, privacy URL, description, keywords, promotional text and What's New in every locale. It replaces the screenshots that changed, waits for the build to finish processing, attaches it, and sets TestFlight's What to Test text.
6. Publishes the GitHub release and prints a summary with a link to the App Store Connect version.

Every step checks what's already there, so if liftoff stops partway (a network error, a slow build), run it again.

## Safety

- No secrets in config. API tokens live in memory only, are valid for 15 minutes, and are sent only to `api.appstoreconnect.apple.com`. Screenshot uploads go to Apple's pre-signed upload URLs, without the token.
- Commands are run directly with an argument list, never through a shell.
- Config paths must stay inside the repo, and unknown config keys are errors.
- Pushing the tag, opening PRs, merging the website PR and renaming an App Store version all ask first, unless you pass `--yes`.
- `--dry-run` runs every read for real and prints every write instead of doing it.

See [SECURITY.md](SECURITY.md) to report a vulnerability.

## Development

```bash
swift build
swift test
```
