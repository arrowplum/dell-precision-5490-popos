# Security Policy

## Scope

This repository ships shell scripts and config snippets that, by design,
run **as root** on a Linux laptop. They install kernel modules
(`v4l2loopback-dkms`), modprobe configs, udev rules, systemd `--user`
units, gstreamer plugins under `/usr/lib`, and binaries under
`/usr/local/bin`. They also clone and compile Intel's `ipu6-camera-bins`,
`ipu6-camera-hal`, and `icamerasrc` from upstream Git.

Any vulnerability that affects how the scripts handle untrusted input,
permissions, file paths, or upstream sources is in scope. Examples:

- Command injection via environment variables or filename expansion.
- Path traversal or symlink races in installer or uninstaller code.
- Insecure file permissions on installed configs or sysfs entries.
- Privilege escalation through the user systemd unit or udev rule.
- Insecure clone or checkout of upstream Intel repositories.

Issues in the underlying kernel, in Intel's IPU6 firmware, in the
upstream Intel camera repositories, or in Pop!\_OS / Ubuntu packages are
**out of scope** for this repository. Report those to the appropriate
upstream project.

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Use GitHub's private vulnerability reporting on this repository:

1. Go to the
   [Security tab](https://github.com/arrowplum/dell-precision-5490-popos/security/advisories)
   of the repo.
2. Click **Report a vulnerability**.
3. Fill in what you found.

If GitHub private reporting is unavailable, open an issue titled
"security: contact request" with **no vulnerability details** and the
maintainer will follow up via the email on their GitHub profile.

Please include in your report:

- The script and approximate line range, or the installed file path.
- A description of the issue and the impact.
- Steps to reproduce, including the exact command(s) run.
- Any proof-of-concept input that triggers the bug.
- The kernel version, distribution, and hardware you tested on.

There is no SLA. This is a personal best-effort repository for a
specific Dell laptop hardware fix.

## Disclosure

After a fix is committed and pushed, the reporter is credited in the
commit message and release notes unless they prefer otherwise.

## Hardening Practices

The scripts try to follow common-sense defenses, but they are **shell
scripts run as root** and the security model is "you read the script
before running it." Specifically:

- All `apt-get` invocations use `DEBIAN_FRONTEND=noninteractive` and
  install only named packages (no glob installs).
- Generated config files at `/etc/modprobe.d/`, `/etc/modules-load.d/`,
  and `/etc/udev/rules.d/` use a `zz-` or numbered prefix and clean up
  prior versions of themselves.
- The installer refuses to run if invoked as `root` without `sudo`,
  because it needs to determine the invoking user's `$HOME` for the
  `--user` systemd unit and wireplumber config.
- The user systemd unit's `ExecStartPost` writes only to a sysfs path
  with mode `g+w` owned by group `video` (set up by an installed udev
  rule). It does not invoke any setuid binary, sudo, or polkit action.

Before running anything, read the script. If you do not understand a
step, do not run it.
