#!/usr/bin/env python3
"""Generate THIRD-PARTY-LICENSES.md attribution files for SSM.

Emits two files so license notices travel with each distributed artifact:

  * ``<repo>/THIRD-PARTY-LICENSES.md``          backend + frontend (docker/app image)
  * ``<repo>/backend/THIRD-PARTY-LICENSES.md``  backend only       (backend/Dockerfile)

Run after dependency changes::

    uv run python backend/scripts/gen_third_party_licenses.py

Requirements: the backend venv (``backend/.venv``) and frontend ``node_modules``
must be installed so the bundled license texts can be read. Missing platform-
conditional packages (e.g. ``colorama``/``tzdata`` on non-Windows/Linux hosts)
fall back to curated standard texts.
"""
from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
FRONTEND = REPO / "frontend"
NM = FRONTEND / "node_modules"

LICENSE_FILE_RE = re.compile(r"^(LICENSE|LICENCE|COPYING|NOTICE)", re.I)


def site_packages() -> Path | None:
    for p in sorted((BACKEND / ".venv/lib").glob("python3.*/site-packages")):
        return p
    return None


SITE = site_packages()


def norm(n: str) -> str:
    return re.sub(r"[-_.]+", "-", n).lower()


# ---------- backend ----------
def backend_prod_names() -> list[str]:
    out = subprocess.run(
        ["uv", "export", "--no-dev", "--no-emit-project", "--format", "requirements-txt"],
        cwd=BACKEND, capture_output=True, text=True,
    ).stdout
    names = []
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith(("#", "-", "--")):
            continue
        m = re.match(r"^([A-Za-z0-9._-]+)", line)
        if m:
            names.append(m.group(1))
    return sorted(set(names), key=str.lower)


def find_distinfo(name: str) -> Path | None:
    if not SITE:
        return None
    target = norm(name)
    for d in SITE.glob("*.dist-info"):
        meta = d / "METADATA"
        if not meta.exists():
            continue
        nm = ""
        for ln in meta.read_text(errors="ignore").splitlines():
            if ln.lower().startswith("name:"):
                nm = ln.split(":", 1)[1].strip()
                break
        if norm(nm) == target:
            return d
    return None


def meta_field(meta_text: str, field: str) -> str:
    for ln in meta_text.splitlines():
        if ln.lower().startswith(field.lower() + ":"):
            return ln.split(":", 1)[1].strip()
        if ln == "":
            break
    return ""


SPDX_NORM = {
    "MIT License": "MIT",
    "BSD": "BSD-3-Clause",
    "The Unlicense (Unlicense)": "Unlicense",
    "Apache Software License": "Apache-2.0",
    "Apache License, Version 2.0": "Apache-2.0",
}

# known SPDX for platform-conditional deps not present on this build host
KNOWN_FALLBACK = {
    "colorama": ("BSD-3-Clause", "Windows-only (transitive via click); not installed on this host"),
    "tzdata": ("Apache-2.0", "non-Linux fallback tz data (transitive via tzlocal); not installed on this host"),
}


def spdx_for(meta_text: str) -> str:
    expr = meta_field(meta_text, "License-Expression")
    if expr:
        return SPDX_NORM.get(expr, expr)
    lic = meta_field(meta_text, "License")
    cls = [ln.split("::")[-1].strip()
           for ln in meta_text.splitlines()
           if ln.startswith("Classifier: License ::")]
    if lic and len(lic) < 60 and "\n" not in lic:
        return SPDX_NORM.get(lic, lic)
    if cls:
        return " / ".join(SPDX_NORM.get(c, c) for c in dict.fromkeys(cls))
    return lic[:60] or "UNKNOWN"


def license_text_from_dist(d: Path) -> str:
    cands = [p for p in d.rglob("*")
             if p.is_file() and LICENSE_FILE_RE.match(p.name)]
    if cands:
        return "\n\n".join(p.read_text(errors="ignore").strip() for p in sorted(cands))
    return ""


def backend_entries() -> list[dict]:
    entries = []
    for name in backend_prod_names():
        d = find_distinfo(name)
        if not d:
            fb = KNOWN_FALLBACK.get(norm(name).replace("-", "")) or KNOWN_FALLBACK.get(name)
            spdx, _ = fb if fb else ("UNKNOWN", "not resolved")
            entries.append({"name": name, "version": "(platform-conditional)",
                            "spdx": spdx, "text": ""})
            continue
        meta = (d / "METADATA").read_text(errors="ignore")
        entries.append({
            "name": meta_field(meta, "Name") or name,
            "version": meta_field(meta, "Version") or "?",
            "spdx": spdx_for(meta),
            "text": license_text_from_dist(d),
        })
    return entries


# ---------- frontend ----------
def frontend_prod_names() -> list[str]:
    if not NM.exists():
        return []
    out = subprocess.run(
        ["npm", "ls", "--omit=dev", "--all", "--json"],
        cwd=FRONTEND, capture_output=True, text=True,
    ).stdout
    try:
        data = json.loads(out)
    except json.JSONDecodeError:
        return []
    seen: set[str] = set()

    def walk(node: dict) -> None:
        for nm, info in (node.get("dependencies") or {}).items():
            seen.add(nm)
            walk(info)

    walk(data)
    return sorted(seen, key=str.lower)


def frontend_entries() -> list[dict]:
    entries = []
    for name in frontend_prod_names():
        pkg_dir = NM / name
        pj = pkg_dir / "package.json"
        if not pj.exists():
            entries.append({"name": name, "version": "?", "spdx": "UNKNOWN", "text": ""})
            continue
        meta = json.loads(pj.read_text(errors="ignore"))
        lic = meta.get("license")
        if isinstance(lic, dict):
            lic = lic.get("type", "UNKNOWN")
        if not lic and meta.get("licenses"):
            lic = " / ".join(item.get("type", "") for item in meta["licenses"])
        text = ""
        for p in sorted(pkg_dir.glob("*")):
            if p.is_file() and LICENSE_FILE_RE.match(p.name):
                text = p.read_text(errors="ignore").strip()
                break
        entries.append({
            "name": name,
            "version": meta.get("version", "?"),
            "spdx": lic or "UNKNOWN",
            "text": text,
        })
    return entries


# ---------- curated texts for components that ship no LICENSE file ----------
_MIT_NATHAN = """The MIT License (MIT)

Copyright (c) 2013 Nathan Rajlich <nathan@tootallnate.net>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE."""

_COLORAMA_BSD = """Copyright (c) 2010 Jonathan Hartley
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

* Redistributions of source code must retain the above copyright notice, this
  list of conditions and the following disclaimer.

* Redistributions in binary form must reproduce the above copyright notice,
  this list of conditions and the following disclaimer in the documentation
  and/or other materials provided with the distribution.

* Neither the name of the copyright holders, nor those of its contributors
  may be used to endorse or promote products derived from this software without
  specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE."""

_VICTORY_VENDOR = """victory-vendor is released under the MIT License by Formidable Labs.
It vendors several d3-* modules which are licensed ISC by Mike Bostock.

--- MIT License (victory-vendor) ---

Copyright (c) 2022 Formidable Labs

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

--- ISC License (vendored d3-* modules) ---

Copyright 2010-2021 Mike Bostock

Permission to use, copy, modify, and/or distribute this software for any purpose
with or without fee is hereby granted, provided that the above copyright notice
and this permission notice appear in all copies.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES WITH
REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND
FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT,
INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS
OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF
THIS SOFTWARE."""

_TZDATA_NOTE = """The Python `tzdata` package is licensed under the Apache License, Version 2.0
(the full text is reproduced elsewhere in this document, e.g. under `bcrypt`).
The bundled IANA Time Zone Database itself is in the public domain.

This package is a platform-conditional dependency (non-Linux fallback) and is
not installed on the build host used to generate this file; the license shown
is its declared SPDX identifier."""

CURATED = {
    "agent-base": _MIT_NATHAN,
    "https-proxy-agent": _MIT_NATHAN,
    "colorama": _COLORAMA_BSD,
    "victory-vendor": _VICTORY_VENDOR,
    "tzdata": _TZDATA_NOTE,
}


# ---------- render ----------
HEADER_INTRO = (
    "Secure SSH Manager (SSM) is licensed under the Business Source License 1.1.\n"
    "It bundles and depends on the third-party components listed below, each under\n"
    "its own license. This file is provided to satisfy the attribution and\n"
    "notice requirements of those licenses.\n"
)
ASYNCSSH_NOTE = (
    "> **Note on `asyncssh`:** offered under `EPL-2.0 OR GPL-2.0-or-later`. SSM\n"
    "> uses it under the **Eclipse Public License 2.0** option, unmodified, as a\n"
    "> library dependency. Source is available from PyPI / the upstream project.\n"
)
GENERATED_NOTE = (
    "> _Generated by `backend/scripts/gen_third_party_licenses.py`. "
    "Regenerate after dependency changes; do not edit by hand._\n"
)


def render(be: list[dict], fe: list[dict], *, scope: str) -> str:
    L = ["# Third-Party Licenses\n", HEADER_INTRO]
    if scope == "backend":
        L.append(
            "> _Scope: backend (Python) production dependencies only — the artifact\n"
            "> built from `backend/Dockerfile`. The combined backend+frontend notice\n"
            "> for the full application image lives in the repository root._\n"
        )
    L.append(ASYNCSSH_NOTE)
    L.append(GENERATED_NOTE)

    def table(title: str, entries: list[dict]) -> None:
        L.append(f"\n## {title}\n")
        L.append("| Component | Version | License |")
        L.append("|-----------|---------|---------|")
        for e in entries:
            L.append(f"| {e['name']} | {e['version']} | {e['spdx']} |")

    sections = [(f"Backend (Python) — {len(be)} components", be)]
    if scope == "combined":
        sections.append((f"Frontend (JavaScript) — {len(fe)} components", fe))
    for title, entries in sections:
        table(title, entries)

    L.append("\n---\n\n# Full License Texts\n")
    full = [("Backend", be)] + ([("Frontend", fe)] if scope == "combined" else [])
    for section, entries in full:
        for e in entries:
            text = e["text"] or CURATED.get(e["name"], "")
            if not text:
                continue
            L.append(f"\n## {e['name']} {e['version']} ({e['spdx']}) — {section}\n")
            if not e["text"]:
                L.append(
                    "*(reconstructed from the package's declared license + upstream "
                    "copyright; the distribution ships no separate LICENSE file)*"
                )
                L.append("")
            L.append("```")
            L.append(text)
            L.append("```")

    pool = be + (fe if scope == "combined" else [])
    missing = [e["name"] for e in pool if not e["text"] and e["name"] not in CURATED]
    if missing:
        L.append("\n---\n\n## Components governed by their SPDX identifier only\n")
        L.append(
            "The following packages ship no separate LICENSE file and are not in the "
            "curated set above; the SPDX identifier in the tables above governs their "
            "use:\n"
        )
        L.extend(f"- {m}" for m in missing)
    return "\n".join(L) + "\n"


def main() -> int:
    if SITE is None:
        print("ERROR: backend venv not found (run `uv sync` in backend/).", file=sys.stderr)
        return 1
    be = backend_entries()
    fe = frontend_entries()
    if not fe:
        print("WARNING: no frontend deps resolved — is frontend/node_modules installed? "
              "Root file will omit the frontend section.", file=sys.stderr)

    combined = REPO / "THIRD-PARTY-LICENSES.md"
    backend_only = BACKEND / "THIRD-PARTY-LICENSES.md"
    combined.write_text(render(be, fe, scope="combined"))
    backend_only.write_text(render(be, [], scope="backend"))

    print(f"backend: {len(be)} components ({sum(1 for e in be if e['text'] or CURATED.get(e['name']))} with text)")
    print(f"frontend: {len(fe)} components ({sum(1 for e in fe if e['text'] or CURATED.get(e['name']))} with text)")
    print(f"wrote {combined.relative_to(REPO)}")
    print(f"wrote {backend_only.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
