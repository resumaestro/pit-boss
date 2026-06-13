# pit-boss

Shared GitHub Actions for the Resumaestro monorepo ecosystem.

## Actions

### `actions/d1-migrate`

Reconciles a Cloudflare D1 database to a target migration version, with sandbox roundtrip testing before anything touches production.

#### How it works

1. Reads the target version from `config.json` (`applied_migration_version`)
2. Reads the applied version from the real DB (`schema_migrations` table)
3. If they match — no-op
4. Creates the sandbox DB if it doesn't exist
5. For **up**: roundtrip-tests each new migration (up → down → schema diff) on the sandbox. Any mismatch aborts — nothing touches the real DB
6. For **down**: dry-runs the rollback on the sandbox first
7. On pass → applies to real DB, caches a snapshot of the final state
8. On fail → restores sandbox from the pre-run snapshot, exits with code 2

Snapshots are cached in GitHub Actions cache under `d1-snap-<db_name>-<version>`, so subsequent runs skip sandbox replay up to the known-good version.

#### Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `db_name` | yes | — | Production D1 database name |
| `sandbox_db_name` | yes | — | Sandbox D1 database name (auto-created if missing) |
| `config_file` | no | `config.json` | Path to config file containing `applied_migration_version` |
| `migrations_dir` | no | `migrations` | Path to directory containing migration files |
| `snaps_dir` | no | `.migration-snaps` | Path to snapshot cache directory |
| `cloudflare_api_token` | yes | — | CF API token with **D1 Edit** scope |
| `cloudflare_account_id` | yes | — | Cloudflare account ID |

#### Outputs

| Output | Description |
|--------|-------------|
| `actual` | Migration version currently applied to the DB |
| `target` | Target migration version from `config.json` |
| `needed` | `true` if a migration was needed |
| `passed` | `true` if the dry-run roundtrip test passed |

---

## Wiring up a new repo

### 1. Migration files

Create a `migrations/` directory with numbered up/down pairs:

```
migrations/
  0001_initial.up.sql
  0001_initial.down.sql
  0002_add_logger_tables.up.sql
  0002_add_logger_tables.down.sql
```

Only the number prefix matters — the name after it is ignored.

### 2. config.json

```json
{ "applied_migration_version": 1 }
```

Bump this number to trigger a migration. Decrease it to trigger a rollback.

### 3. GitHub repo settings

| Setting | Value |
|---------|-------|
| Secret: `CLOUDFLARE_API_TOKEN` | CF API token with D1 Edit scope |
| Var: `CLOUDFLARE_ACCOUNT_ID` | `281f6b8969eb59a0dec34daaafd69a29` |
| Environment: `sandbox-lock` | No protection rules — concurrency is enforced by GitHub's single-deployment-at-a-time behavior |
| Branch rule: `main` | Enable merge queue |

### 4. Workflows

**.github/workflows/migrate.yml** — runs on merge to main:

```yaml
name: Migrate D1

on:
  push:
    branches: [main]
    paths:
      - "config.json"
      - "migrations/**"
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: migrate
  cancel-in-progress: false

jobs:
  dry-run:
    runs-on: ubuntu-latest
    environment: sandbox-lock
    outputs:
      passed: ${{ steps.migrate.outputs.passed }}
      needed: ${{ steps.migrate.outputs.needed }}
      actual: ${{ steps.migrate.outputs.actual }}
      target: ${{ steps.migrate.outputs.target }}
    steps:
      - uses: actions/checkout@v4

      - name: Run migration
        id: migrate
        uses: resumaestro/pit-boss/actions/d1-migrate@main
        with:
          db_name: <your-db-name>
          sandbox_db_name: <your-db-name>-sandbox
          cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare_account_id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}

  migrate:
    needs: dry-run
    if: needs.dry-run.outputs.needed == 'true' && needs.dry-run.outputs.passed == 'true'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Apply migrations to production
        uses: resumaestro/pit-boss/actions/d1-migrate@main
        with:
          db_name: <your-db-name>
          sandbox_db_name: <your-db-name>-sandbox
          cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare_account_id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}

  revert:
    needs: dry-run
    if: needs.dry-run.outputs.needed == 'true' && needs.dry-run.outputs.passed == 'false'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - name: Open revert PR
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          BRANCH="revert/migration-${{ github.sha }}"
          BRANCH="${BRANCH:0:50}"
          git config user.name  "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git checkout -b "$BRANCH"
          git revert --no-edit "${{ github.sha }}"
          git push origin "$BRANCH"
          gh pr create \
            --repo <org>/<repo> \
            --title "Revert: migration dry-run failed (${{ github.sha }})" \
            --body "Sandbox roundtrip test failed. Nothing was applied to the real DB. Fix the migration and re-merge." \
            --base main \
            --head "$BRANCH"
```

**.github/workflows/migrate-pr.yml** — runs on PRs to main:

```yaml
name: Migrate D1 (PR dry-run)

on:
  pull_request:
    branches: [main]
    paths:
      - "config.json"
      - "migrations/**"

permissions:
  contents: read
  pull-requests: write

jobs:
  dry-run:
    runs-on: ubuntu-latest
    environment: sandbox-lock
    steps:
      - uses: actions/checkout@v4

      - name: Run migration dry-run
        id: migrate
        uses: resumaestro/pit-boss/actions/d1-migrate@main
        with:
          db_name: <your-db-name>
          sandbox_db_name: <your-db-name>-sandbox
          cloudflare_api_token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare_account_id: ${{ vars.CLOUDFLARE_ACCOUNT_ID }}

      - name: Comment result on PR
        if: always() && steps.migrate.outputs.needed == 'true'
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if [[ "${{ steps.migrate.outputs.passed }}" == "true" ]]; then
            BODY="✅ Migration dry-run passed. Migrations ${{ steps.migrate.outputs.actual }} → ${{ steps.migrate.outputs.target }} roundtrip-tested successfully on sandbox."
          else
            BODY="❌ Migration dry-run failed. Check the [workflow run](${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}) for details."
          fi
          gh pr comment ${{ github.event.pull_request.number }} \
            --repo <org>/<repo> \
            --body "$BODY"

      - name: Fail if dry-run did not pass
        if: steps.migrate.outputs.needed == 'true' && steps.migrate.outputs.passed == 'false'
        run: exit 1
```

### 5. Rollback

To roll back, decrease `applied_migration_version` in `config.json` and merge. The script will dry-run the downs on the sandbox first, then apply to the real DB.
