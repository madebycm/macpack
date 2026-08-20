# Security

MacPack intentionally grants a narrow operation—installing a macOS package—the same root authority that Installer.app receives after authentication. Because package scripts run as root, the privileged boundary is treated as production infrastructure even though the product is optimized for trusted, high-volume workflows.

## Controls

- The launch daemon accepts only a client satisfying the root-owned designated code-signing requirement generated for MacPack.app.
- XPC exposes `ping` and `installPackage`; there is no arbitrary command endpoint.
- Package paths must be absolute, exist after symlink resolution, and end in `.pkg` or `.mpkg`.
- `/usr/sbin/installer` is launched directly with an argv array. No shell parses package paths.
- Installs are serialized.
- MacPack does not disable Gatekeeper, use `-allowUntrusted`, store passwords, edit sudoers, or make the helper setuid.
- The helper is launch-on-demand and exits after work completes.

The package’s own payload and scripts are still privileged code. Only open packages you intend to install.

## Reporting

Please do not post exploitable privileged-helper issues in a public issue. Email the repository owner through the address on their GitHub profile with reproduction steps and the affected commit. Non-sensitive hardening improvements are welcome as ordinary pull requests.
