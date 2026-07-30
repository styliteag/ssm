# SSM — Elixir/Phoenix stack

The application itself. See the repository root [README](../README.md) for the full
picture and [AGENTS.md](../AGENTS.md) for the operating manual.

The toolchain is docker-only — no local Elixir needed:

```bash
just dev       # dev server on http://localhost:4000 (docker compose up)
just test      # ExUnit suite
just verify    # compile --warnings-as-errors + format check + tests
just mix ...   # any mix task inside the dev container
```

Production image: `Dockerfile` (build context = repository root), deployed via
`../docker/compose.yml`.
