# supabase-ping

Minimal Cloud Run service that pings Supabase Cloud projects on a schedule to
prevent them from pausing due to inactivity. Cloud Scheduler triggers the
service twice per week via OIDC-authenticated POST.

## Projects pinged

| Name | Supabase URL | Key source |
|------|-------------|------------|
| copilotkit-forms | `yiggjfcwpagbupsmueax.supabase.co` | secret `copilotkit-forms-supabase-anon-key` |
| new-permit-dashboard | `abpozothizwzigutzndg.supabase.co` | secret `SUPABASE_SERVICE_ROLE_KEY` |
| permitflow | `hslyuwjkdceklrunjmxv.supabase.co` | secret `permitflow-supabase-key` |
| prythian-permits | `rzrijalijuliromqgmqp.supabase.co` | env on `prythian-permits` service |
| prythian-reviewworks | `erbzeaejjomjqmbhclpj.supabase.co` | env on `prythian-permits` service |

Self-hosted Supabase instances (project-a, project-b) are excluded — they don't
pause for inactivity.

## Why twice per week?

Supabase pauses free-tier projects after **7 days** of inactivity. A single
weekly ping leaves zero margin — if one ping fails, the project sleeps. Twice
per week (Monday + Thursday, 3–4 day gaps) means a single failure still leaves
the next ping within the 7-day window.

## Architecture

```
Cloud Scheduler (cron: Mon & Thu 08:00 UTC)
    │  POST /ping  (OIDC auth)
    ▼
Cloud Run  supabase-ping  (scale-to-zero, 256 Mi, us-east4)
    │  reads SUPABASE_PROJECTS_JSON from Secret Manager (env mount)
    │  for each project → GET /rest/v1/{table}?select=id&limit=1
    ▼
Returns JSON with per-project status; HTTP 500 if any fail
```

Code deploys automatically via Cloud Build on push to `main`
(`direwolfvm/supabase-ping`).

## Cost

Effectively **$0/month**. All usage falls within GCP free tier:
- Cloud Run: ~8 requests/month, ~40 vCPU-seconds total
- Cloud Scheduler: 1 job (3 free per account)
- Secret Manager: ~8 access operations/month

## Deploy

`deploy.sh` assembles the `SUPABASE_PROJECTS_JSON` secret automatically from
existing secrets and Cloud Run env vars in `permitting-ai-helper`, then wires
up IAM and Cloud Scheduler.

```bash
chmod +x deploy.sh
./deploy.sh
```

After the script completes, push to `main` to trigger Cloud Build and deploy
the actual code.

## Table setup

Each Supabase project needs a table readable by the anon key. Default table
name is `healthcheck`. Run this SQL in each project's SQL editor:

```sql
CREATE TABLE IF NOT EXISTS public.healthcheck (
  id int PRIMARY KEY DEFAULT 1
);
INSERT INTO public.healthcheck (id) VALUES (1) ON CONFLICT DO NOTHING;
ALTER TABLE public.healthcheck ENABLE ROW LEVEL SECURITY;
CREATE POLICY "anon read" ON public.healthcheck FOR SELECT USING (true);
```

Or set `"table": "existing_table"` per project in the JSON secret.

## Secret format

`deploy.sh` creates this automatically, but for reference:

```json
[
  {"name": "copilotkit-forms",     "url": "https://yiggjfcwpagbupsmueax.supabase.co", "anon_key": "sb_..."},
  {"name": "new-permit-dashboard", "url": "https://abpozothizwzigutzndg.supabase.co", "anon_key": "eyJ..."},
  {"name": "permitflow",           "url": "https://hslyuwjkdceklrunjmxv.supabase.co", "anon_key": "sb_..."},
  {"name": "prythian-permits",     "url": "https://rzrijalijuliromqgmqp.supabase.co", "anon_key": "sb_..."},
  {"name": "prythian-reviewworks", "url": "https://erbzeaejjomjqmbhclpj.supabase.co", "anon_key": "sb_..."}
]
```

To add/remove projects, update the secret only — no redeployment needed:

```bash
gcloud secrets versions add SUPABASE_PROJECTS_JSON \
  --data-file=/tmp/projects.json \
  --project=permitting-ai-helper
```

## Test

```bash
# Trigger scheduler manually
gcloud scheduler jobs run supabase-ping-twice-weekly \
  --location=us-east4 --project=permitting-ai-helper

# Call Cloud Run directly
URL=$(gcloud run services describe supabase-ping \
  --region=us-east4 --format="value(status.url)" --project=permitting-ai-helper)
TOKEN=$(gcloud auth print-identity-token)
curl -X POST -H "Authorization: Bearer ${TOKEN}" "${URL}/ping"

# Test locally
export SUPABASE_PROJECTS_JSON='[{"name":"test","url":"https://xxx.supabase.co","anon_key":"...","table":"healthcheck"}]'
pip install -r requirements.txt
python app.py &
curl -X POST http://localhost:8080/ping
```

## Logs

```bash
gcloud logging read \
  'resource.type="cloud_run_revision" AND resource.labels.service_name="supabase-ping"' \
  --limit=20 --format=json --project=permitting-ai-helper
```
