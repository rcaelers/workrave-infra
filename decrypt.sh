 sops -d -i apps/guardrail-config/overlays/development/02-secrets.yaml 
 sops -d -i apps/guardrail-config/overlays/production/02-secrets.yaml 
 sops -d -i apps/guardrail-db/overlays/production/guardrail-db-secrets.yaml 
 sops -d -i apps/guardrail-db/overlays/production/postgresql-secrets.yaml 
 sops -d -i apps/guardrail-db/overlays/development/postgresql-secrets.yaml 
 sops -d -i apps/guardrail-db/overlays/development/guardrail-db-secrets.yaml 
 sops -d -i apps/minio/overlays/development/minio-secrets.yaml 
 sops -d -i apps/minio/overlays/production/minio-secrets.yaml