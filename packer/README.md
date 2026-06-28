```
# Authenticate (one of these):
gcloud auth application-default login
# or point at a service account key:
export GOOGLE_APPLICATION_CREDENTIALS="/path/to/sa-key.json"

packer init .
packer fmt .
packer validate -var "project_id=YOUR_PROJECT" .
packer build  -var "project_id=YOUR_PROJECT" .

packer validate -var-file=variables.pkrvars.hcl . 
packer build  -var-file=variables.pkrvars.hcl .

```
