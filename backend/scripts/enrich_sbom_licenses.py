#!/usr/bin/env python3
"""Inject SPDX license data into the backend CycloneDX SBOM.

``cyclonedx-py requirements`` builds components from a requirements file and
cannot read installed package metadata, so it leaves the ``licenses`` field
empty. This reads the licenses from the installed ``backend/.venv`` dist-info
(reusing :mod:`gen_third_party_licenses`) and writes them back into
``sbom/ssm-backend.cdx.json``.

Run via :file:`gen_sbom.sh`, or directly::

    uv run python backend/scripts/enrich_sbom_licenses.py
"""
from __future__ import annotations

import importlib.util
import json
import re
from pathlib import Path

HERE = Path(__file__).resolve()
REPO = HERE.parents[2]
GEN = HERE.parent / "gen_third_party_licenses.py"
SBOM = REPO / "sbom" / "ssm-backend.cdx.json"

_spec = importlib.util.spec_from_file_location("gen_tpl", GEN)
gen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(gen)

SPDX_ID_RE = re.compile(r"^[A-Za-z0-9.+-]+$")


def license_node(spdx: str) -> list[dict]:
    spdx = spdx.strip()
    if not spdx or spdx == "UNKNOWN":
        return []
    if " OR " in spdx or " AND " in spdx or "(" in spdx:
        return [{"expression": spdx}]
    if SPDX_ID_RE.match(spdx):
        return [{"license": {"id": spdx}}]
    return [{"license": {"name": spdx}}]


def main() -> int:
    if not SBOM.exists():
        raise SystemExit(f"ERROR: {SBOM} not found — run gen_sbom.sh first.")
    data = json.loads(SBOM.read_text())
    enriched = 0
    for comp in data.get("components", []):
        name = comp.get("name", "")
        d = gen.find_distinfo(name)
        if d:
            spdx = gen.spdx_for((d / "METADATA").read_text(errors="ignore"))
        else:
            fb = (gen.KNOWN_FALLBACK.get(gen.norm(name).replace("-", ""))
                  or gen.KNOWN_FALLBACK.get(name))
            spdx = fb[0] if fb else "UNKNOWN"
        node = license_node(spdx)
        if node:
            comp["licenses"] = node
            enriched += 1
    SBOM.write_text(json.dumps(data, indent=2) + "\n")
    print(f"enriched {enriched}/{len(data.get('components', []))} backend components")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
