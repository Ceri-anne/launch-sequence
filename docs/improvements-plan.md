# Improvements plan

Fixes and improvements that came out of releasing Prime Time 1.2.0 with launchseq. Each item names the problem we actually hit, then the change.

Suggested order: **1 → 2 → 4 → 3 → 5 → 8 → 6 → 7**. PRs 2 and 4 caused the most confusion in that release. PR 8 comes before 6 so PR 6 can reuse its per-image matching. Every PR adds tests using the existing `FakeASC` and `LineSink` fakes.

## 1. Wait longer for screenshot processing, with progress

**Problem:** liftoff failed twice with "Screenshot still processing after 5 minutes". Apple took about 10–15 minutes per set.

**Status:** done on branch `screenshot-processing-progress` (`206881e`). Not merged or released yet.

- `waitForScreenshots` waits up to 30 minutes and prints `x/y processed by Apple (<elapsed>)` every 30 seconds.
- On a timeout it says how many screenshots are still processing, and that rerunning liftoff skips the sets that have finished.
- Left to do: open the PR, merge it, then tag a release so Homebrew picks it up.

## 2. Progress output and prompts

**Problem:** long steps ran with no output, so it was unclear whether launchseq was working or stuck.

- **Say what's happening.** `Support/Console.swift` gets a "doing X…" line before every long step, plus a "still waiting (<elapsed>)" line for any step that runs longer than about 15 seconds. That covers the simulator boot, tests, each capture, rendering, translation, the CI checks wait and uploads.
- **Confirm the Duo fold/unfold prompt.** When the user presses Enter at the pause in `Screenshots/Screenshots.swift`, print `Got it, capturing the inner display…` straight away. Also say that the terminal needs focus, because a keypress sent to another window is silently lost.
- **Fix the editor.** `Support/Shell.swift` starts the release-notes editor through `Process`, which puts it in its own process group, so vi gets stopped by SIGTTOU (state `T`) and never appears. Run the editor in the terminal's foreground process group (for example through `posix_spawn` with `tcsetpgrp`). If that can't be made reliable, print the file's path and wait for Enter instead.

## 3. Resuming and reruns (countdown)

- **Rerunning after a failure.** If a step fails after countdown's own captures are written (Playwright was missing this time), a rerun refuses with "working tree isn't clean". Allow uncommitted changes when they're all in the paths countdown generates (screenshots, release notes) and the saved run state matches this run. Keep refusing for any other change.
- **Stale framed screenshots.** With `--skip-screenshots`, re-render whenever the raw captures are newer than the framed images. Without this, the framed images were stale even though the raw captures were up to date.
- **Release-branch history.** Always start `release/<version>` from `origin/main`, and never amend a commit countdown didn't make. One run made a branch whose first commit was an amended copy of a commit already on `main`.

## 4. CI checks (liftoff)

- **No checks yet.** When `Git.checks` finds no check runs for the commit, keep polling for a few minutes (with progress) instead of failing straight away.
- **Main workflow didn't run.** Xcode Cloud's Main workflow didn't trigger on the rebase-and-merge push, so liftoff kept reporting "No CI checks". If no build has started, offer to start one through the App Store Connect API (`POST ciBuildRuns` for the Main workflow on `refs/heads/main`), then wait for its checks.
- **Website PR race.** The website PR's checks were reported as "failed" before any had registered, and the build then passed. Wait for checks to appear, and report "no checks" differently from "failed".

## 5. Doctor

- Check that Playwright and Chromium are installed (`node -e "require('playwright')"`), and print the install command if they aren't: `npm install --no-save playwright && npx playwright install chromium`.
- Warn if the App Store Connect key can't read the CI endpoints that PR 4 needs (`ciProducts`, `ciWorkflows`).

## 6. Product page Header and Search Results images

**Problem:** launchseq doesn't upload `CreativeAssets/<lang>/header.png` or `search-results.png`, so they have to be added by hand on the version page.

- First find out which App Store Connect API endpoint takes these images, and whether App Store Connect carries them over to a new version.
- Then add the upload to liftoff, skipping images that haven't changed, using the per-image matching from PR 8.
- Optionally, have countdown run the project's product-page render script again when its inputs change (headlines, subtitle, the screenshots it uses).

## 7. Watch status bar

`Screenshots.swift` runs `simctl status_bar <udid> override` (default `--time 9:41`) for every device, the Watch simulator included.

- Capture once and check whether the override works on watchOS.
- If it doesn't, either allow a Watch-specific `status_bar` in the config, or have doctor say the override isn't supported there.
- Test: the override arguments are built per device, and a Watch entry uses its own `status_bar` when one is set.

## 8. Replace only the screenshots that changed

**Problem:** `syncScreenshots` is all-or-nothing per set. If anything differs, it deletes the whole set and uploads every screenshot again, so adding one screenshot uploads four, and one failed image re-uploads the rest.

- Add `--skip-screenshots` to liftoff, like `--skip-website`, so a rerun can skip the Screenshots step. For now, the only way is a copy of the config with the `screenshots:` section removed, passed with `--config`. Print a warning that skipped locales keep whatever screenshots App Store Connect already has.
- Compare screenshots one at a time:
  - Keep any screenshot whose file name and checksum match and whose state is `COMPLETE`.
  - Delete the ones that don't match or failed, and upload the missing ones.
  - Then set the order with `PATCH appScreenshotSets/{id}/relationships/appScreenshots`.
- Only wait for the screenshots that were just uploaded.
- Tests:
  - A screenshot appended to a set: only that one uploads.
  - One changed in the middle: only that one is replaced, and the order is kept.
  - One removed locally: it's deleted.
  - A `FAILED` screenshot: it's uploaded again.
