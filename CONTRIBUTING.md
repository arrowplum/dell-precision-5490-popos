# Contributing

Thank you for considering a contribution. This is a small repo with a
narrow scope: get audio and the internal IPU6 webcam working on a Dell
Precision 5490 running Pop!\_OS 24.04 with kernel 6.18.

Contributions in the same spirit are welcome. Examples:

- Fixes for the same hardware on a related kernel or distro.
- Support for close-cousin laptops with the same Meteor Lake + OV01A10
  + IVSC config (Latitude 7340 / 7440 / 7640 etc).
- A real green-tint / AWB fix (see "Future work" in the README).
- Documentation improvements.

If your change is broad (e.g. adapting the bridge to a different ISP
pipeline or a different sensor), please open an issue first so we can
agree on whether it fits this repo or wants its own.

## Reporting bugs

- **Do not open a public GitHub issue for security vulnerabilities.**
  See [SECURITY.md](SECURITY.md) for the private reporting flow.

- For everything else, open a GitHub issue with:
  - The exact laptop model and CPU (`sudo dmidecode -s system-product-name`
    and `lscpu | head`).
  - Kernel and distro (`uname -r` and `lsb_release -d`).
  - The script you ran and its full output.
  - For runtime issues: `journalctl --user -u camera-bridge.service`
    output and `wpctl status` output.

## Submitting a patch

1. Open a pull request against `main`.
2. Describe the problem and the fix in the PR body. Link any related
   issue.
3. Keep the change minimal and focused. One concern per PR.
4. Test on real hardware before opening the PR if at all possible. If
   you cannot, say so in the PR body so reviewers know.

There is no required commit message format or sign-off. Plain English
in the body is fine. Conventional commits style is welcome but not
required.

## Code style

- Shell scripts use `#!/usr/bin/env bash`, `set -euo pipefail`, and
  the existing `log` / `warn` / `die` helpers.
- Indent with 4 spaces in shell, 2 spaces in markdown / config files.
- Comments explain *why* something is done, not *what* the code does.
  The why is often a kernel quirk or a specific failure mode; document
  those.
- Prefer numeric-sorted prefixes for installed config files
  (`52-...conf`, `70-...rules`, `zz-...conf`) so ordering is explicit.

## Code of Conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Be kind. We are all
trying to get a webcam to work.

## License

By contributing, you agree that your contributions are licensed under
the [Apache License 2.0](LICENSE), the same as the rest of the repo.
