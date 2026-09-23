---
title: Backup credentials (Cloudflare R2)
description: Create the R2 bucket and the S3 access key pair Conductor needs to upload database backups, and avoid the API-token confusion that silently breaks uploads.
order: 8
---

# Backup credentials (Cloudflare R2)

A backup needs two things that are easy to confuse: a **bucket** to write to, and
an **S3 access key pair** to write with. Conductor can create the bucket for you.
It deliberately does **not** mint the key pair — see [Why Conductor doesn't mint
keys](#why-conductor-doesnt-mint-keys).

## The one mistake worth naming first

Cloudflare's R2 token screen shows you **two different things**:

| What you see | What it is | Use it for backups? |
|---|---|---|
| **Token value** (`v1.0-…`) | A Cloudflare **API token** — a bearer token for the Cloudflare REST API | **No** |
| **Access Key ID** + **Secret Access Key** | An **S3 credential pair** | **Yes** |

Backups upload over the S3 protocol (`aws s3 cp`), which can only authenticate
with the key pair. An API token pasted into the same field looks completely
valid — right account, right permissions, no error on save — and then every
upload fails at the storage layer. Copy the **bottom** pair, not the top value.

## 1. Create the bucket

In Conductor, on the backup form, use **Create bucket** next to the bucket name
field, or over MCP:

```
conductor_storage action=create_bucket bucket=<name>
```

Creating an existing bucket is a no-op, so it is safe to re-run. Bucket names
must be lowercase letters, digits, and hyphens (3–63 chars).

Region: leave the location hint unset unless you have a reason. **It cannot be
changed after creation** — moving data later means creating a second bucket and
copying.

## 2. Create the S3 key pair

In the Cloudflare dashboard, in **the account that owns the bucket** (an R2
token is account-scoped and cannot reach buckets in another account):

1. **R2** → **API** → **Manage API tokens** → **Create API token**.
2. **Token name**: something traceable, e.g. `conductor-backups`.
3. **Permissions**: **Object Read & Write**.
   Not *Admin Read & Write* — backups never create or delete buckets, and a
   backup credential that can delete a bucket can delete your backups.
4. **Specify bucket(s)**: **Apply to specific buckets** → your backup bucket.
   Scoping matters: this key will sit on Conductor and be used by every app.
5. **TTL**: no expiry, unless you have a rotation process that will actually
   rotate it. An expiring backup credential fails silently at 3am.
6. *(Optional)* **Client IP filtering**: the **app servers'** public IPs, not
   Conductor's. Dumps are produced and uploaded on the box being backed up.
7. **Create**, then copy **Access Key ID** and **Secret Access Key**. The secret
   is shown **once**.

## 3. Store it in Conductor

**Credentials → New credential**:

| Field | Value |
|---|---|
| Name | e.g. `R2 backups (<bucket>)` |
| Provider | Cloudflare |
| API key | **Access Key ID** |
| API secret | **Secret Access Key** |
| Account ID | The Cloudflare account that owns the bucket |

The account ID is required — it forms the S3 endpoint
`https://<account_id>.r2.cloudflarestorage.com`.

Re-saving a credential with the secret field left blank **keeps** the stored
secret. To replace it, paste the new one; to remove it, use the explicit clear
action.

## 4. Point backups at it and prove it works

On each backup, set **Credential** and **Bucket**, then **Run now**. Do not stop
at a green status — open the run and confirm:

- the dump is a valid gzip archive (checked before upload);
- the object was **confirmed present in the bucket** after upload, by asking the
  bucket, not by the exit code of the upload;
- a **restore verification** succeeded — the dump was restored into a throwaway
  Postgres container and the table count reported.

That last one is the only evidence that matters. A backup that has never been
restored is a hypothesis.

## Why Conductor doesn't mint keys

Creating an R2 access key requires a Cloudflare token with **User API Tokens:
Edit** — a credential that can create credentials. Conductor holding that would
mean a compromise of Conductor becomes a durable compromise of the whole
Cloudflare account, with attacker-issued keys that outlive the intrusion and no
audit trail outside the system you would be investigating.

So the line is: **Conductor creates resources; humans mint credentials.** A
bucket carries no authority, so Conductor creates buckets. A key is authority,
so a person issues it and hands it over.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Upload fails, credential looks right | An API token was pasted instead of the Access Key ID / Secret pair |
| `NoSuchBucket` | Bucket is in a different Cloudflare account than the token, or was never created |
| `aws: command not found` | The AWS CLI is missing on the **app server** — the upload runs there, not on the Conductor host |
| `AccessDenied` on upload | Token scoped to specific buckets, but not this one |
| Dump uploads but restore verification fails | The dump is truncated or corrupt — the backup was never usable; treat as a failure |
