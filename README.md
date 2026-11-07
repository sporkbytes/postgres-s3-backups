# Deploy a Cron Job to Backup PostgreSQL to Amazon S3

This repo can be used to deploy a [Cron Job](https://render.com/docs/cronjobs) on [Render](https://render.com) to backup a PostgreSQL instance to Amazon S3.

Fork this repo and click the button below to deploy.

## Multi-region backups

Set `S3_TARGETS` to a comma-separated list of `region:bucket` pairs, for example:

```
us-west-2:my-db-backups-west,us-east-1:my-db-backups-east
```

The first entry is the stream target: the job runs `pg_dump`, gzips it, and uploads directly to that bucket. Each remaining target receives a copy of the same object key via S3→S3 (no second dump, no large temp file on the cron disk). Put the region closest to your database first.

Your IAM user/role needs permission to create/configure buckets (if auto-create is used), list and put objects on every target bucket, and get objects from the first (primary) bucket so copies can run.

A single `region:bucket` pair is valid if you only need one region.

## Postgres / Alpine versions

You'll need to set corresponding OS and Postgres versions:

| `POSTGRES_VERSION` | `ALPINE_VERSION` |
| :----------------: | :--------------: |
| 18                 | 3.23             |
| 17                 | 3.21             |
| 16                 | 3.20             |
| 15                 | 3.20             |
| 14                 | 3.20             |
| 13                 | 3.19             |
| 12                 | 3.18             |

[![Deploy to Render](https://render.com/images/deploy-to-render-button.svg)](https://render.com/deploy)

See the guide at https://render.com/docs/backup-postgresql-to-s3 for more information.
