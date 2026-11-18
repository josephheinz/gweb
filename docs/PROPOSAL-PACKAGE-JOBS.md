# Proposal: jobs from a package

Status: proposal (goose-cms ask 11). Not implemented in 1.6.

## Problem

`app/jobs.goose` belongs to the app: its `enum Job`, `fn run` and `fn schedule` are the only ones. A package cannot
add jobs, so `cms new` scaffolds an `app/jobs.goose` whose `Job` must have a variant named `Cms`, because
`cms::schedule` writes `jobs::Job.Cms`. A package's jobs should need no scaffolding and no naming rule.

## Today

- The queue holds bytes: `to_bytes` of a one-item `jobs::Job[>..]`. A runner decodes `jobs::Job[>..]` and calls
  `jobs::run`. Nothing tags which enum the bytes are.
- `jobs::enqueue`, `every`, `every_local` and `cron` are generated for `jobs::Job` only.
- Schedule names share one space; a duplicate exits the server with 1.
- `jobs.goose` anywhere but the app's `app/` is a build error.

## Proposal

1. **File.** A package may have `jobs.goose` at the top of its `app/` (its mount's root), with the same contract:
   `enum Job`, `fn run(job: const Job&, ctx: gweb::Ctx&) -> bool`, optional `fn schedule(s: gweb::Schedules&)`.
   Its namespace is `NAME_jobs` (`cms_jobs` for package `cms`), so the package writes `cms_jobs::Job.Backup`.
   A package without a mount has no `app/`; it would put the file at `jobs.goose` beside `gweb.package`.
2. **Queue.** Each job's bytes start with one source byte: 0 for the app, k for the k-th package with jobs, in
   `gweb.packages` order. The runner matches on it and decodes that source's enum. The queue is in memory, so the
   change needs no migration.
3. **API.** gweb generates `NAME_jobs::enqueue(ctx, job, delay_ms)`, `every`, `every_local` and `cron` beside the
   app's `jobs::` ones. Retries, backoff, `job_attempts` and `--no-schedule` apply to all.
4. **Schedules.** `main` calls the app's `jobs::schedule`, then each package's in `gweb.packages` order. A package's
   names are stored as `NAME:name` (`cms:backup`) in logs and duplicate checks, so they never collide with the app's.
5. **Overrides.** None in the first version. An app that wants to change a package's schedule turns it off through
   the package's own config (an environment variable the package reads in `schedule`).

## Decisions needed

- The namespace (`cms_jobs`) and where an unmounted package's file goes.
- Whether schedule names are prefixed (`cms:backup`), which changes what logs and metrics show.
- Whether the app can disable a package's schedule by name (`gweb.packages`: `no-schedule cms:backup`), or only the
  package can.

## Cost

About 200 lines in `cli/gweb.goose` (scan, the generated enqueue and schedule helpers, the runner's match) and a
`test/jobs` package fixture. No change to `ops/jobs.goose` or `src/jobs.c`: they move bytes.

## goose-cms after it

Delete the scaffolded `app/jobs.goose` and its `Cms` variant; move the backup job into the package's
`app/jobs.goose` as `cms_jobs::Job.Backup`, scheduled by the package's `fn schedule`.
