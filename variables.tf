variable "aws_region" {

  # region to deploy resources
  type    = string
  default = "ap-southeast-1" # SG region - Using this . by priority, terraform should take this over the main.tf default
}