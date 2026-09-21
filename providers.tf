provider "aws" {
  region  = var.region
  profile = var.profile

  default_tags {
    tags = {
      Project   = "SD-lab03"
      ManagedBy = "Terraform"
      Owner     = "stephanie.borrego"
    }
  }
}

provider "acme" {
  server_url = var.letsencrypt_staging ? "https://acme-staging-v02.api.letsencrypt.org/directory" : "https://acme-v02.api.letsencrypt.org/directory"
}
