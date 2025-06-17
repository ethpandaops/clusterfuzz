#!/bin/bash
PROJECT_ID="ethpandaops-clusterfuzz"
BUCKETS=(
    "${PROJECT_ID}-blobs"
    "${PROJECT_ID}-deployment"
    "${PROJECT_ID}-corpus"
    "${PROJECT_ID}-quarantine"
    "${PROJECT_ID}-backup"
    "${PROJECT_ID}-coverage"
    "${PROJECT_ID}-fuzzer-logs"
    "${PROJECT_ID}-fuzz-logs"
    "${PROJECT_ID}-bigquery"
)

echo "Creating buckets for project: $PROJECT_ID"
for bucket in "${BUCKETS[@]}"; do
    echo "Creating bucket: gs://$bucket"
    gsutil mb -p $PROJECT_ID gs://$bucket
done

echo "Setting lifecycle policies..."
# Create lifecycle policy files
cat > 14days.json << 'POLICY'
{
  "lifecycle": {
    "rule": [{
      "action": {"type": "Delete"},
      "condition": {"age": 14}
    }]
  }
}
POLICY

cat > 90days.json << 'POLICY'
{
  "lifecycle": {
    "rule": [{
      "action": {"type": "Delete"},
      "condition": {"age": 90}
    }]
  }
}
POLICY

cat > 100days.json << 'POLICY'
{
  "lifecycle": {
    "rule": [{
      "action": {"type": "Delete"},
      "condition": {"age": 100}
    }]
  }
}
POLICY

# Set 14-day deletion for log buckets
gsutil lifecycle set 14days.json gs://${PROJECT_ID}-fuzzer-logs
gsutil lifecycle set 14days.json gs://${PROJECT_ID}-fuzz-logs

# Set 90-day deletion for quarantine
gsutil lifecycle set 90days.json gs://${PROJECT_ID}-quarantine

# Set 100-day deletion for backups
gsutil lifecycle set 100days.json gs://${PROJECT_ID}-backup

# Clean up policy files
rm 14days.json 90days.json 100days.json

echo "Buckets created successfully!"