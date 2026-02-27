#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy.sh — Wire up supabase-ping on permitting-ai-helper
#
# The Cloud Run service + Cloud Build trigger already exist.
# This script:
#   1. Assembles SUPABASE_PROJECTS_JSON from existing secrets/env vars
#   2. Stores it in Secret Manager
#   3. Wires the secret into the Cloud Run service
#   4. Creates IAM + Cloud Scheduler job
#
# Usage: chmod +x deploy.sh && ./deploy.sh
# ---------------------------------------------------------------------------
set -euo pipefail

PROJECT_ID="permitting-ai-helper"
REGION="us-east4"
SERVICE_NAME="supabase-ping"
SA_NAME="supabase-ping-sa"
SCHEDULER_SA_NAME="supabase-ping-scheduler"
SECRET_NAME="SUPABASE_PROJECTS_JSON"
JOB_NAME="supabase-ping-twice-weekly"

SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
SCHEDULER_SA_EMAIL="${SCHEDULER_SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"

# ---------------------------------------------------------------------------
# 1. Enable APIs
# ---------------------------------------------------------------------------
echo "==> 1/7 Enabling APIs..."
gcloud services enable \
  secretmanager.googleapis.com \
  cloudscheduler.googleapis.com \
  --project="${PROJECT_ID}"

# ---------------------------------------------------------------------------
# 2. Assemble SUPABASE_PROJECTS_JSON from existing secrets & env vars
# ---------------------------------------------------------------------------
echo "==> 2/7 Assembling SUPABASE_PROJECTS_JSON from existing secrets..."

# Read keys from Secret Manager
KEY_COPILOTKIT=$(gcloud secrets versions access latest \
  --secret=copilotkit-forms-supabase-anon-key --project="${PROJECT_ID}")
KEY_NEW_PERMIT=$(gcloud secrets versions access latest \
  --secret=SUPABASE_SERVICE_ROLE_KEY --project="${PROJECT_ID}")
KEY_PERMITFLOW=$(gcloud secrets versions access latest \
  --secret=permitflow-supabase-key --project="${PROJECT_ID}")

# Read inline keys from Cloud Run service env vars
KEY_PRYTHIAN=$(gcloud run services describe prythian-permits \
  --project="${PROJECT_ID}" --region="${REGION}" --format=json \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
envs=d['spec']['template']['spec']['containers'][0]['env']
print(next(e['value'] for e in envs if e['name']=='VITE_SUPABASE_ANON_KEY'))
")
KEY_REVIEWWORKS=$(gcloud run services describe prythian-permits \
  --project="${PROJECT_ID}" --region="${REGION}" --format=json \
  | python3 -c "
import sys,json
d=json.load(sys.stdin)
envs=d['spec']['template']['spec']['containers'][0]['env']
print(next(e['value'] for e in envs if e['name']=='REVIEWWORKS_SUPABASE_ANON_KEY'))
")

# Build the JSON
PROJECTS_JSON=$(python3 -c "
import json
projects = [
    {
        'name': 'copilotkit-forms',
        'url': 'https://yiggjfcwpagbupsmueax.supabase.co',
        'anon_key': '''${KEY_COPILOTKIT}'''
    },
    {
        'name': 'new-permit-dashboard',
        'url': 'https://abpozothizwzigutzndg.supabase.co',
        'anon_key': '''${KEY_NEW_PERMIT}'''
    },
    {
        'name': 'permitflow',
        'url': 'https://hslyuwjkdceklrunjmxv.supabase.co',
        'anon_key': '''${KEY_PERMITFLOW}'''
    },
    {
        'name': 'prythian-permits',
        'url': 'https://rzrijalijuliromqgmqp.supabase.co',
        'anon_key': '''${KEY_PRYTHIAN}'''
    },
    {
        'name': 'prythian-reviewworks',
        'url': 'https://erbzeaejjomjqmbhclpj.supabase.co',
        'anon_key': '''${KEY_REVIEWWORKS}'''
    }
]
print(json.dumps(projects, indent=2))
")

echo "    Assembled ${PROJECTS_JSON}" | head -c 200
echo "..."
echo ""

# ---------------------------------------------------------------------------
# 3. Store in Secret Manager
# ---------------------------------------------------------------------------
echo "==> 3/7 Storing SUPABASE_PROJECTS_JSON in Secret Manager..."
gcloud secrets create "${SECRET_NAME}" \
  --replication-policy="automatic" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (secret already exists)"

echo "${PROJECTS_JSON}" | gcloud secrets versions add "${SECRET_NAME}" \
  --data-file=- --project="${PROJECT_ID}"
echo "    Secret version created."

# ---------------------------------------------------------------------------
# 4. Create Cloud Run service account + grant secret access
# ---------------------------------------------------------------------------
echo "==> 4/7 Creating service account and granting secret access..."
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="Supabase Ping Cloud Run SA" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (SA already exists)"

gcloud secrets add-iam-policy-binding "${SECRET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role="roles/secretmanager.secretAccessor" \
  --project="${PROJECT_ID}" --quiet

# ---------------------------------------------------------------------------
# 5. Update Cloud Run service (code deploys via Cloud Build on push)
# ---------------------------------------------------------------------------
echo "==> 5/7 Updating Cloud Run service config..."
gcloud run services update "${SERVICE_NAME}" \
  --region="${REGION}" \
  --service-account="${SA_EMAIL}" \
  --set-secrets="SUPABASE_PROJECTS_JSON=${SECRET_NAME}:latest" \
  --no-allow-unauthenticated \
  --min-instances=0 \
  --max-instances=1 \
  --memory=256Mi \
  --timeout=60 \
  --project="${PROJECT_ID}"

CLOUD_RUN_URL=$(gcloud run services describe "${SERVICE_NAME}" \
  --region="${REGION}" \
  --format="value(status.url)" \
  --project="${PROJECT_ID}")
echo "    URL: ${CLOUD_RUN_URL}"

# ---------------------------------------------------------------------------
# 6. Create Scheduler service account + grant run.invoker
# ---------------------------------------------------------------------------
echo "==> 6/7 Setting up Scheduler service account..."
gcloud iam service-accounts create "${SCHEDULER_SA_NAME}" \
  --display-name="Supabase Ping Scheduler SA" \
  --project="${PROJECT_ID}" 2>/dev/null || echo "    (SA already exists)"

gcloud run services add-iam-policy-binding "${SERVICE_NAME}" \
  --region="${REGION}" \
  --member="serviceAccount:${SCHEDULER_SA_EMAIL}" \
  --role="roles/run.invoker" \
  --project="${PROJECT_ID}" --quiet

# ---------------------------------------------------------------------------
# 7. Create Cloud Scheduler job — Mon & Thu 08:00 UTC
# ---------------------------------------------------------------------------
echo "==> 7/7 Creating Cloud Scheduler job..."

# Delete existing job if present (idempotent re-runs)
gcloud scheduler jobs delete "${JOB_NAME}" \
  --location="${REGION}" \
  --project="${PROJECT_ID}" --quiet 2>/dev/null || true

gcloud scheduler jobs create http "${JOB_NAME}" \
  --location="${REGION}" \
  --schedule="0 8 * * 1,4" \
  --time-zone="UTC" \
  --uri="${CLOUD_RUN_URL}/ping" \
  --http-method=POST \
  --oidc-service-account-email="${SCHEDULER_SA_EMAIL}" \
  --oidc-token-audience="${CLOUD_RUN_URL}" \
  --attempt-deadline="120s" \
  --project="${PROJECT_ID}"

echo ""
echo "============================================================"
echo "  DONE"
echo ""
echo "  Service : ${CLOUD_RUN_URL}"
echo "  Schedule: Mon & Thu at 08:00 UTC"
echo "  Job     : ${JOB_NAME}"
echo ""
echo "  Code deploys automatically on push to main via Cloud Build."
echo ""
echo "  Test now:"
echo "    gcloud scheduler jobs run ${JOB_NAME} \\"
echo "      --location=${REGION} --project=${PROJECT_ID}"
echo ""
echo "  View logs:"
echo "    gcloud logging read 'resource.type=\"cloud_run_revision\"' \\"
echo "      ' AND resource.labels.service_name=\"${SERVICE_NAME}\"' \\"
echo "      --limit=20 --format=json --project=${PROJECT_ID}"
echo "============================================================"
