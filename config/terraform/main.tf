
module "clusterfuzz" {
  source = "github.com/google/clusterfuzz/infra/terraform"
  project_id    = "ethpandaops-clusterfuzz"
  secondary_project_id = "ethpandaops-clusterfuzz"
  region        = "us-central1"
  subnet_name   = "us-central1"
  network_name  = "main"
  ip_cidr_range = "10.128.0.0/16"
}
terraform {
  backend "gcs" {
    bucket = "clusterfuzz-terraform-state-bucket"
    prefix = "ethpandaops-clusterfuzz"
  }
}