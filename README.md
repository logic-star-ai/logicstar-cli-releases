# logicstar-cli

Install the [logicstar](https://logicstar.ai) CLI on your machine.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/logic-star-ai/logicstar-cli-releases/main/install.sh | sh
```

Installs to `~/.local/bin/logicstar`. Make sure that directory is on your `PATH`, then run `logicstar install` to register Claude Code / Cursor integrations.

The installer verifies SHA-256 against the published `checksums.txt`. Subsequent upgrades through `logicstar update` additionally verify an ed25519 signature against the public key pinned in the binary.

## Updates

`logicstar` checks for updates in the background. To check now:

```sh
logicstar update
```

## Supported platforms

macOS (Apple Silicon, Intel) · Linux (x86_64, ARM64).

## Support

Email [support@logicstar.ai](mailto:support@logicstar.ai) or reach out in the customer Slack.
