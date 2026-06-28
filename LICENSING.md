# Licensing

Secure SSH Manager (SSM) is **source-available** software, licensed under the
**Business Source License 1.1 (BSL 1.1)**. See [`LICENSE`](LICENSE) for the full
legal text. This page is a plain-language summary — the `LICENSE` file governs in
case of any conflict.

## The short version

- The **source code is public**. You may read it, build it, modify it, run it for
  your own organization, and contribute back.
- You may **not** turn it into a competing commercial offering. Specifically, you
  may not host it for third parties as a service, or resell/redistribute it for a
  fee, without a **commercial license** from STYLiTE.
- Every released version **automatically becomes open source (GPL v3.0 or later)**
  four years after it was published. BSL is a time-delayed open source license, not
  a permanent lock-up.

> BSL is **not** an OSI-approved "Open Source" license. The correct term for it is
> *source-available*.

## What you may do for free

| Use case | Allowed under BSL? |
| --- | --- |
| Read, audit, and learn from the source | ✅ Yes |
| Build and run it to manage SSH access on **your own** hosts / your own organization's | ✅ Yes |
| Modify it and run your modified version internally | ✅ Yes |
| Submit issues and pull requests | ✅ Yes (see *Contributing* below) |
| Use a version that is **past its Change Date** for anything (it is GPLv3 then) | ✅ Yes |

## What needs a commercial license

| Use case | Allowed under BSL? |
| --- | --- |
| Offer SSM to **third parties** as a hosted / managed / multi-tenant service | ❌ Needs a commercial license |
| Manage **your customers'** hosts with it as a paid service (MSP use) | ❌ Needs a commercial license |
| Resell, sublicense, rent, or redistribute it for a fee | ❌ Needs a commercial license |
| Embed it in a paid product you sell to others | ❌ Needs a commercial license |

If you want to do any of the above, contact **office@stylite.de** for a
commercial / hosting license.

## Why BSL?

We want the code to stay open and inspectable — security software should be
auditable, and the community should be able to build, fix, and extend it. At the
same time, the hosting and commercial resale of SSM is how STYLiTE funds its
development. BSL lets us keep both: open source you can run yourself, with the
commercial-service rights reserved to STYLiTE until each version ages into full
GPLv3.

## The "Change Date" — automatic conversion to open source

Each released version is published under BSL and flips to the **Change License
(GPL v3.0 or later)** on the earlier of:

1. the **Change Date** stated in `LICENSE`, or
2. the **fourth anniversary** of that version's first public release.

After that date, that version is full GPLv3 with no restrictions. When cutting a
release, bump the `Change Date` in `LICENSE` so it tracks the new version
(roughly release date + 4 years).

## Contributing

By submitting a contribution (pull request, patch) you agree that STYLiTE may
license your contribution under both the current BSL 1.1 and the future Change
License, and may include it in commercially licensed versions. A formal
Contributor License Agreement (CLA) may be required before larger contributions
are merged — this keeps the copyright consolidated so the dual model stays
enforceable.

## Trademark

"STYLiTE" and "Secure SSH Manager" are trademarks of STYLiTE. The BSL grants no
rights to the names or logos — a permitted fork must be distributed under a
different name.

---

*This document is an informational summary and not legal advice. The
[`LICENSE`](LICENSE) file is the binding agreement.*
