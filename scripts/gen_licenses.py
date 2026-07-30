#!/usr/bin/env python3
"""Generate THIRD-PARTY-LICENSES.md + sbom.cdx.json from shipped runtime deps.

Stdlib-only; run via ``just notices``. Ported from
../dashboard/dashboard-open/scripts/gen_notices.py (orbit cutover pattern).

Two sources, both restricted to what actually ships in the production image:

* phoenix  -> ``mix.lock`` closure, license + text from the fetched Hex deps
* vendored -> single files bundled verbatim into the compiled assets (topbar)

Dev/test tooling is intentionally excluded: it is not part of the distributed
artifact, so its licenses impose no attribution obligation on the image.
Needs the hex deps fetched on disk (``just mix deps.get`` fills
``phoenix/data/deps`` via the dev container's bind mount).
"""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "THIRD-PARTY-LICENSES.md"
SBOM_OUT = ROOT / "sbom.cdx.json"

PHOENIX = ROOT / "phoenix"
# Dev bind-mount cache (compose.yml mounts ./data/deps to /app/deps);
# bare phoenix/deps is the fallback for a host-side `mix deps.get`.
DEPS_DIRS = (PHOENIX / "data" / "deps", PHOENIX / "deps")

# mix.lock entries NOT shipped in the release: dev/test-only apps, their
# closures, and build-time tooling (runtime: false / asset compilers).
# Everything else in the lock lands in `mix release` and carries an
# attribution obligation.
_EXCLUDE = {
    "phoenix_live_reload",  # only: :dev
    "file_system",  # phoenix_live_reload dependency (dev-only closure)
    "lazy_html",  # only: :test
    "fine",  # lazy_html NIF helper (test-only closure)
    "esbuild",  # runtime only in :dev; the binary never ships
    "tailwind",  # same
    "elixir_make",  # runtime: false build tool (exqlite/bcrypt NIF builds)
    "cc_precompiler",  # same
}

# Sparse git checkouts (assets subtree only) carry no LICENSE file — both
# upstreams are MIT; link the canonical text instead of bundling none.
_GIT_LICENSES = {
    "heroicons": ("MIT", "https://github.com/tailwindlabs/heroicons/blob/master/LICENSE"),
    "daisyui": ("MIT", "https://github.com/saadeghi/daisyui/blob/master/LICENSE"),
}


def _deps_dir() -> Path | None:
    return next((d for d in DEPS_DIRS if d.is_dir()), None)


def _lock_entries() -> list[tuple[str, str, str]]:
    """(name, version, ecosystem) from mix.lock — hex and git entries."""
    lock = PHOENIX / "mix.lock"
    if not lock.exists():
        return []
    text = lock.read_text()
    rows: list[tuple[str, str, str]] = []
    for m in re.finditer(r'"([a-z0-9_]+)": \{:hex, :[a-z0-9_]+, "([^"]+)"', text):
        rows.append((m.group(1), m.group(2), "hex"))
    # Git deps (heroicons/daisyui): sparse asset checkouts compiled INTO the
    # shipped css/components — attribution needed even though they are not
    # OTP apps in the release.
    for m in re.finditer(r'"([a-z0-9_]+)": \{:git, "([^"]+)", "([a-f0-9]{7,40})"', text):
        rows.append((m.group(1), m.group(3)[:12], "github:" + m.group(2)))
    return rows


def _hex_license(dep_dir: Path) -> str:
    meta = dep_dir / "hex_metadata.config"
    if meta.exists():
        m = re.search(r'\{<<"licenses">>,\[(.*?)\]\}', meta.read_text(errors="replace"))
        if m:
            names = re.findall(r'<<"([^"]+)">>', m.group(1))
            if names:
                return " AND ".join(names)
    text = _license_text(dep_dir) or ""
    if "MIT License" in text or text.startswith("MIT"):
        return "MIT"
    return "UNKNOWN"


def _license_text(dep_dir: Path) -> str | None:
    for pattern in ("LICENSE*", "LICENCE*", "*/LICENSE*"):
        for p in sorted(dep_dir.glob(pattern)):
            if p.is_file():
                return p.read_text(errors="replace")
    return None


def collect_phoenix() -> list[dict]:
    """Hex/git runtime deps of the phoenix release."""
    deps_dir = _deps_dir()
    rows: list[dict] = []
    for name, version, eco in sorted(_lock_entries()):
        if name in _EXCLUDE:
            continue
        dep_dir = deps_dir / name if deps_dir else None
        has_dir = dep_dir is not None and dep_dir.is_dir()
        license_name = _hex_license(dep_dir) if has_dir else "UNKNOWN"
        text = _license_text(dep_dir) if has_dir else None

        if license_name == "UNKNOWN" and name in _GIT_LICENSES:
            license_name, canonical = _GIT_LICENSES[name]
            text = f"MIT — sparse asset checkout bundles no license file.\nFull text: {canonical}"

        rows.append(
            {
                "name": name,
                "version": version,
                "license": license_name,
                "url": (
                    eco.removeprefix("github:")
                    if eco.startswith("github:")
                    else f"https://hex.pm/packages/{name}"
                ),
                "text": text,
                "_eco": eco,
            }
        )
    return rows


def collect_vendored() -> list[dict]:
    """Single files bundled verbatim into the compiled assets."""
    rows: list[dict] = []
    topbar = PHOENIX / "assets" / "vendor" / "topbar.js"
    if topbar.exists():
        src = topbar.read_text(errors="replace")
        m = re.search(r"topbar (\d+\.\d+\.\d+)", src)
        header = re.search(r"/\*\*.*?\*/", src, re.S)
        rows.append(
            {
                "name": "topbar (bundled into app.js)",
                "version": m.group(1) if m else "unknown",
                "license": "MIT",
                "url": "http://buunguyen.github.io/topbar",
                "text": header.group(0) if header else None,
                "_purl_name": "topbar",
            }
        )
    return rows


# --------------------------------------------------------------------------- #
# render
# --------------------------------------------------------------------------- #
def _table(rows: list[dict]) -> str:
    lines = ["| Component | Version | License |", "|---|---|---|"]
    for r in rows:
        lines.append(f"| {r['name']} | {r['version']} | {r['license']} |")
    return "\n".join(lines)


def _texts(rows: list[dict]) -> str:
    blocks: list[str] = []
    for r in rows:
        head = f"### {r['name']} {r['version']} — {r['license']}"
        if r.get("url"):
            head += f"\n\n<{r['url']}>"
        if r.get("text"):
            blocks.append(f"{head}\n\n```\n{r['text'].strip()}\n```")
        else:
            blocks.append(
                f"{head}\n\n_No license file bundled by the distributor; see the link above._"
            )
    return "\n\n".join(blocks)


def render(phoenix: list[dict], vendored: list[dict]) -> str:
    return "\n".join(
        [
            "# Third-Party Licenses",
            "",
            "Secure SSH Manager (SSM) is distributed under the Business Source License 1.1",
            "(see `LICENSE`). It bundles the third-party open-source components listed below,",
            "each under its own license. **This file is generated — do not edit by hand.**",
            "Regenerate with `just notices` after changing runtime dependencies.",
            "",
            "Only components shipped in the production container are listed; build/test-only",
            "tooling is excluded as it is not part of the distributed artifact.",
            "",
            "## Elixir/Hex runtime (release image)",
            "",
            _table(phoenix),
            "",
            "## Vendored (bundled verbatim)",
            "",
            _table(vendored),
            "",
            "---",
            "",
            "## Full license texts",
            "",
            "### Elixir/Hex",
            "",
            _texts(phoenix),
            "",
            "### Vendored",
            "",
            _texts(vendored),
            "",
        ]
    )


# --------------------------------------------------------------------------- #
# SBOM (CycloneDX 1.6)
# --------------------------------------------------------------------------- #
def _cdx_license(value: str) -> list[dict]:
    v = (value or "").strip()
    if not v or v == "UNKNOWN":
        return []
    if " OR " in v or " AND " in v or " WITH " in v:
        return [{"expression": v}]  # SPDX license expression
    # A single bare token (e.g. MIT, BSD-3-Clause) is a usable SPDX id;
    # anything with spaces (e.g. "MIT License") is a free-text name, not an id.
    if re.fullmatch(r"[A-Za-z0-9.+-]+", v):
        return [{"license": {"id": v}}]
    return [{"license": {"name": v}}]


def _cdx_components(rows: list[dict]) -> list[dict]:
    comps: list[dict] = []
    for r in rows:
        eco = r.get("_eco", "")
        if eco.startswith("github:"):
            repo = eco.removeprefix("github:").removeprefix("https://github.com/")
            repo = repo.removesuffix(".git")
            purl = f"pkg:github/{repo}@{r['version']}"
        elif eco == "hex":
            purl = f"pkg:hex/{r['name']}@{r['version']}"
        else:
            name = r.get("_purl_name", r["name"])
            purl = f"pkg:generic/{name}@{r['version']}"
        comp = {
            "type": "library",
            "bom-ref": purl,
            "name": r.get("_purl_name", r["name"]),
            "version": r["version"],
            "purl": purl,
        }
        lic = _cdx_license(r["license"])
        if lic:
            comp["licenses"] = lic
        comps.append(comp)
    return comps


def build_sbom(phoenix: list[dict], vendored: list[dict]) -> dict:
    version = (ROOT / "VERSION").read_text().strip() if (ROOT / "VERSION").exists() else "unknown"
    return {
        "bomFormat": "CycloneDX",
        "specVersion": "1.6",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "bom-ref": "stylite-ssm",
                "name": "stylite-ssm",
                "version": version,
            }
        },
        "components": _cdx_components(phoenix) + _cdx_components(vendored),
    }


def main() -> None:
    phoenix = collect_phoenix()
    if not phoenix:
        raise SystemExit(
            "no hex deps found — run 'just mix deps.get' first (fills phoenix/data/deps)"
        )
    unknown = [r["name"] for r in phoenix if r["license"] == "UNKNOWN"]
    vendored = collect_vendored()
    OUT.write_text(render(phoenix, vendored))
    sbom = build_sbom(phoenix, vendored)
    SBOM_OUT.write_text(json.dumps(sbom, indent=2, ensure_ascii=False) + "\n")
    n = len(phoenix) + len(vendored)
    print(f"wrote {OUT.relative_to(ROOT)} ({len(phoenix)}+{len(vendored)} components)")
    print(f"wrote {SBOM_OUT.relative_to(ROOT)} (CycloneDX 1.6, {n} components)")
    if unknown:
        print(f"WARNING: no license detected for: {', '.join(unknown)}")


if __name__ == "__main__":
    main()
