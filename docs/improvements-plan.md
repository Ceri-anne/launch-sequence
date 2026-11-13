# Improvements plan

Fixes and improvements that came out of releasing Prime Time 1.2.0 (items 1–8) and Bigger or Smaller 1.1.0 (items 9–13) with launchseq. Each item names the problem we actually hit, then the change.

Suggested order for what's left: **12 → 13 → 10 → 11 → 5 → 8 → 9 → 6 → 7**. 12 and 13 are small output fixes. 10 and 11 stop blank screenshots from being committed and uploaded. PR 8 comes before 6 so PR 6 can reuse its per-image matching. Every PR adds tests using the existing `FakeASC` and `LineSink` fakes.

## 1. Wait longer for screenshot processing, with progress

**Problem:** liftoff failed twice with "Screenshot still processing after 5 minutes". Apple took about 10–15 minutes per set.

**Status:** released in 0.2.0.

- `waitForScreenshots` waits up to 30 minutes and prints `x/y processed by Apple (<elapsed>)` every 30 seconds.
- On a timeout it says how many screenshots are still processing, and that rerunning liftoff skips the sets that have finished.

## 2. Progress output and prompts

**Status:** released in 0.2.0.

**Problem:** long steps ran with no output, so it was unclear whether launchseq was working or stuck.

- **Say what's happening.** `Support/Console.swift` gets a "doing X…" line before every long step, plus a "still waiting (<elapsed>)" line for any step that runs longer than about 15 seconds. That covers the simulator boot, tests, each capture, rendering, translation, the CI checks wait and uploads.
- **Confirm the Duo fold/unfold prompt.** When the user presses Enter at the pause in `Screenshots/Screenshots.swift`, print `Got it, capturing the inner display…` straight away. Also say that the terminal needs focus, because a keypress sent to another window is silently lost.
- **Fix the editor.** `Support/Shell.swift` starts the release-notes editor through `Process`, which puts it in its own process group, so vi gets stopped by SIGTTOU (state `T`) and never appears. Run the editor in the terminal's foreground process group (for example through `posix_spawn` with `tcsetpgrp`). If that can't be made reliable, print the file's path and wait for Enter instead.

## 3. Resuming and reruns (countdown)

**Status:** released in 0.2.0.

- **Rerunning after a failure.** If a step fails after countdown's own captures are written (Playwright was missing this time), a rerun refuses with "working tree isn't clean". Allow uncommitted changes when they're all in the paths countdown generates (screenshots, release notes) and the saved run state matches this run. Keep refusing for any other change.
- **Stale framed screenshots.** With `--skip-screenshots`, re-render whenever the raw captures are newer than the framed images. Without this, the framed images were stale even though the raw captures were up to date.
- **Release-branch history.** Always start `release/<version>` from `origin/main`, and never amend a commit countdown didn't make. One run made a branch whose first commit was an amended copy of a commit already on `main`.

## 4. CI checks (liftoff)

**Status:** released in 0.2.0.

- **No checks yet.** When `Git.checks` finds no check runs for the commit, keep polling for a few minutes (with progress) instead of failing straight away.
- **Main workflow didn't run.** Xcode Cloud's Main workflow didn't trigger on the rebase-and-merge push, so liftoff kept reporting "No CI checks". If no build has started, offer to start one through the App Store Connect API (`POST ciBuildRuns` for the Main workflow on `refs/heads/main`), then wait for its checks.
- **Website PR race.** The website PR's checks were reported as "failed" before any had registered, and the build then passed. Wait for checks to appear, and report "no checks" differently from "failed".

## 5. Doctor

- Check that Playwright and Chromium are installed (`node -e "require('playwright')"`), and print the install command if they aren't: `npm install --no-save playwright && npx playwright install chromium`.
- Warn if the App Store Connect key can't read the CI endpoints that PR 4 needs (`ciProducts`, `ciWorkflows`).
- Check that every `screenshots.devices` simulator boots, not just that it exists.
- Xcode 27 has no Simulator.app; its simulator window is `DeviceHub.app` inside Xcode. Anything that tells the person to open the simulator should name Device Hub.

## 6. Product page Header and Search Results images

**Problem:** launchseq doesn't upload `CreativeAssets/<lang>/header.png` or `search-results.png`, so they have to be added by hand on the version page.

- First find out which App Store Connect API endpoint takes these images, and whether App Store Connect carries them over to a new version.
- Then add the upload to liftoff, skipping images that haven't changed, using the per-image matching from PR 8.
- Optionally, have countdown run the project's product-page render script again when its inputs change (headlines, subtitle, the screenshots it uses). Bigger or Smaller's Header and Search Results images went stale this way: they're built from the 6.9" question and reveal captures, which countdown now retakes, but nothing re-renders them.

## 7. Watch status bar

`Screenshots.swift` runs `simctl status_bar <udid> override` (default `--time 9:41`) for every device, the Watch simulator included.

- Capture once and check whether the override works on watchOS.
- If it doesn't, either allow a Watch-specific `status_bar` in the config, or have doctor say the override isn't supported there.
- Test: the override arguments are built per device, and a Watch entry uses its own `status_bar` when one is set.

## 8. Replace only the screenshots that changed

**Status:** partly released in 0.2.0. Liftoff now uploads screenshots one at a time and, on a rerun, keeps the ones at the start of a set that already match. `upload: manual` (or `--manual-screenshots`) lets you drag sets in by hand. Full per-image matching and `--skip-screenshots` are still to do.

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

## 9. Amend a release before it's submitted (liftoff)

**Problem:** Bigger or Smaller 1.1.0 was tagged and prepared in App Store Connect, then a UI change (Settings moved to a gear on Home) was merged that belonged in the same release. Liftoff resumes from the existing tag, so there was no supported way to bring it in. Doing it by hand meant:
- fixing the release notes, which described where Settings used to be
- force-pushing the tag to the new commit
- deleting and re-adding it to make it annotated, since `git tag -f` without `-a` had made it lightweight. Each push started an Xcode Cloud Release build, so two builds came from the same commit.
- running liftoff again to attach the newer build

- Add `liftoff --retag`, allowed only while the App Store Connect version is `PREPARE_FOR_SUBMISSION` (never after Submit for Review). It would:
  - list the commits on `main` since the tag and ask for confirmation
  - recreate the tag as an annotated tag on the new commit, in a single `git push --force` of the tag ref
  - point the GitHub release at the new tag
  - wait for the new build and attach it, as liftoff already does
- Even without `--retag`, have liftoff warn when `origin/main` has commits since the release tag whose subjects aren't excluded by `release_notes.ignore`. Those are changes the release won't include, and the release notes may now describe the app wrongly.
- Tests:
  - `--retag` refuses once the version is submitted.
  - The new tag is annotated.
  - The tag is pushed once.
  - Liftoff attaches the newest build from after the retag, not the older one.

## 10. Catch blank screenshot captures (countdown)

**Problem:** the first captures of a freshly installed app were the empty app background: the screen had drawn nothing by the default 3-second `settle_seconds`. The warm-up launch didn't help for screens that do more work (a scripted reveal, a summary). Countdown would have framed those blanks, committed them to the release PR, and liftoff would have uploaded them. Bigger or Smaller now sets `warmup_seconds: 5` and `settle_seconds: 5`.

- After each capture, check whether the image is nearly one colour (for example, more than 99% of sampled pixels within a small distance of the most common colour, ignoring the status bar strip). If it is, wait `settle_seconds` again and capture again, up to twice. Then fail with the scene, device and a hint to raise `settle_seconds`.
- Consider a default `settle_seconds` of 5, or settling until two captures a second apart are identical.
- Tests:
  - A uniform image is detected as blank.
  - A real capture isn't.
  - A blank capture is retried, and capturing fails after the last retry.

## 11. Doctor: take one real capture

**Problem:** `simctl io screenshot` run from a sandboxed shell (an agent's sandbox, for one) returns a correctly sized but blank frame for every app, system apps included, with no error. It took a while to tell that apart from item 10.

- Doctor boots the first screenshot device, launches a system app (Settings, `com.apple.Preferences`), takes one capture and runs item 10's blank check on it.
- If it's blank, report that screen capture isn't working from this shell, and suggest running launchseq from a normal terminal.

## 12. Say when screenshots are skipped (liftoff)

**Problem:** for a config with no `screenshots:` section, liftoff skips the screenshot step without a word, so it looked as if it had uploaded them. The person assumed launchseq had handled them.

- When `config.screenshots` is nil, print `Screenshots: skipped (no screenshots: section in .launchseq.yml; App Store Connect keeps the previous version's)`.
- Add a `Screenshots: not managed` line to the "Ready for review" summary.

## 13. Accurate GitHub release messages (liftoff)

**Problem:** on a rerun, where the release was already published, liftoff printed `[dry run] would: gh release edit 1.1.0 --draft=false --latest` followed by `✓ Published GitHub release 1.1.0`. In a dry run that reads as if publishing happened, and either way nothing needed doing.

- Before publishing, check the release with `gh release view <tag> --json isDraft`. If it's already published, print `GitHub release <tag> already published` and skip the edit.
- In a dry run, never print a ✓ line for a step that was only previewed.
