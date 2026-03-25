#!/bin/bash
# ============================================
# Setup script for Google Cloud Static Hosting
# Run this once to configure your GCP project
# ============================================
#
# Prerequisites:
#   - gcloud CLI installed (https://cloud.google.com/sdk/docs/install)
#   - A GCP project created
#   - Billing enabled on the project
#
# Usage:
#   chmod +x setup-gcp.sh
#   ./setup-gcp.sh <PROJECT_ID> <BUCKET_NAME>
#
# Example:
#   ./setup-gcp.sh my-tax-budget-project tax-budget-site
#
# After running this script, add these GitHub Secrets:
#   GCS_BUCKET_NAME          = your bucket name
#   GCP_SERVICE_ACCOUNT      = deploy-sa@<PROJECT_ID>.iam.gserviceaccount.com
#   GCP_WORKLOAD_IDENTITY_PROVIDER = (printed at the end of this script)

set -euo pipefail

PROJECT_ID="${1:?Usage: $0 <PROJECT_ID> <BUCKET_NAME>}"
BUCKET_NAME="${2:?Usage: $0 <PROJECT_ID> <BUCKET_NAME>}"
REGION="me-west1"  # Tel Aviv region
SA_NAME="deploy-sa"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_NAME="github-pool"
PROVIDER_NAME="github-provider"
GITHUB_REPO="menmenash/tax_budget"

echo "==> Setting project to ${PROJECT_ID}"
gcloud config set project "${PROJECT_ID}"

echo "==> Enabling required APIs"
gcloud services enable storage.googleapis.com iamcredentials.googleapis.com

# ---- Create Cloud Storage bucket ----
echo "==> Creating bucket gs://${BUCKET_NAME} in ${REGION}"
gcloud storage buckets create "gs://${BUCKET_NAME}" \
  --location="${REGION}" \
  --uniform-bucket-level-access \
  --public-access-prevention=inherited \
  2>/dev/null || echo "    Bucket already exists, skipping."

echo "==> Configuring static website"
gcloud storage buckets update "gs://${BUCKET_NAME}" \
  --web-main-page-suffix=index.html \
  --web-not-found-page=index.html

echo "==> Making bucket publicly readable"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member=allUsers \
  --role=roles/storage.objectViewer

# ---- Create Service Account ----
echo "==> Creating service account ${SA_NAME}"
gcloud iam service-accounts create "${SA_NAME}" \
  --display-name="GitHub Deploy SA" \
  2>/dev/null || echo "    SA already exists, skipping."

echo "==> Granting Storage Admin on bucket"
gcloud storage buckets add-iam-policy-binding "gs://${BUCKET_NAME}" \
  --member="serviceAccount:${SA_EMAIL}" \
  --role=roles/storage.objectAdmin

# ---- Workload Identity Federation (keyless auth from GitHub Actions) ----
echo "==> Creating Workload Identity Pool"
gcloud iam workload-identity-pools create "${POOL_NAME}" \
  --location="global" \
  --display-name="GitHub Actions Pool" \
  2>/dev/null || echo "    Pool already exists, skipping."

echo "==> Creating OIDC Provider for GitHub"
gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_NAME}" \
  --location="global" \
  --workload-identity-pool="${POOL_NAME}" \
  --display-name="GitHub Provider" \
  --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository" \
  --attribute-condition="assertion.repository=='${GITHUB_REPO}'" \
  --issuer-uri="https://token.actions.githubusercontent.com" \
  2>/dev/null || echo "    Provider already exists, skipping."

WORKLOAD_IDENTITY_PROVIDER=$(gcloud iam workload-identity-pools providers describe "${PROVIDER_NAME}" \
  --location="global" \
  --workload-identity-pool="${POOL_NAME}" \
  --format="value(name)")

echo "==> Allowing GitHub Actions to impersonate the SA"
gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/${WORKLOAD_IDENTITY_PROVIDER}/attribute.repository/${GITHUB_REPO}"

# ---- Print results ----
BUCKET_URL="https://storage.googleapis.com/${BUCKET_NAME}/index.html"

echo ""
echo "============================================"
echo " Setup complete!"
echo "============================================"
echo ""
echo " Your site URL:"
echo "   ${BUCKET_URL}"
echo ""
echo " Add these GitHub Secrets (Settings > Secrets > Actions):"
echo ""
echo "   GCS_BUCKET_NAME"
echo "   ${BUCKET_NAME}"
echo ""
echo "   GCP_SERVICE_ACCOUNT"
echo "   ${SA_EMAIL}"
echo ""
echo "   GCP_WORKLOAD_IDENTITY_PROVIDER"
echo "   ${WORKLOAD_IDENTITY_PROVIDER}"
echo ""
echo " Then push to main and the workflow will deploy automatically."
echo ""
echo " Optional: For a custom domain, set up a Cloud Load Balancer"
echo " or use Firebase Hosting with a custom domain."
echo "============================================"
