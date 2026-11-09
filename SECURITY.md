# Security

launchseq handles App Store Connect API keys, which can publish apps. Please report vulnerabilities privately using GitHub's **Report a vulnerability** button on this repo's Security tab, not in a public issue.

## Design rules

These rules are deliberate, and changes that weaken them won't be merged:

- **No secrets in the repo or in app config.** Credentials come from the environment, a `chmod 600` file under `~/.config/launchseq/`, or the macOS Keychain. Files that group or others can read are refused.
- **Tokens are kept in memory only, valid for 15 minutes, and never logged.** `--verbose` prints methods and paths, never headers.
- **Fixed hosts.** The JWT is only ever sent to `https://api.appstoreconnect.apple.com`. Screenshot data only goes to `https://*.apple.com` upload URLs that App Store Connect returns, with no Authorization header. Paging links that point anywhere else are refused. The Anthropic API key is only ever sent to `https://api.anthropic.com`.
- **No shell.** Every command is a `Process` started with an argument array, so no value from config, git or the network can be interpreted as shell syntax.
- **Validated input.** Config is decoded strictly, so unknown keys are errors. Paths must be relative and are resolved, including through symlinks, to stay inside the repo. Names used as file names, branch names and version numbers are restricted to safe characters.
- **Confirmations.** Steps that publish something (pushing a tag or branch, opening or merging PRs, renaming an App Store version) ask first. Nothing ever submits an app for review.
- **Minimal dependencies**, pinned to exact versions: swift-argument-parser and Yams.
