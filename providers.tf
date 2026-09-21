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
