variable "project_name" {
  type    = string
  default = "vote-app"
}

variable "region" {
  type    = string
  default = "eu-west-3"
}

variable "instance_type" {
  type    = string
  default = "t2.micro"
}

variable "my_ip_cidr" {
  description = "Your public IP in CIDR format (e.g. 1.2.3.4/32)"
  type        = string
}

variable "public_key_path" {
  description = "Path to your SSH public key (e.g. ~/.ssh/id_rsa.pub)"
  type        = string
}

# If your Result app needs to connect to Postgres directly, set true.
variable "allow_vote_result_to_postgres" {
  type    = bool
  default = true
}
