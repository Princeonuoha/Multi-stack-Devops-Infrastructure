terraform {
  backend "s3" {
    bucket         = "prince-terraform-state-eu-central-1"
    key            = "project101/terraform.tfstate"
    region         = "eu-central-1"
    dynamodb_table = "PO-terraform-state-locks"
    encrypt        = true
  }
}
