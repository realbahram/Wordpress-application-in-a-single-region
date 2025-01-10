variable "az_num" {
  type    = number
  default = 2
}

variable "namespace" {
  type    = string
  default = "bahram-workshop"
}

variable "vpc_cidr_block" {
  type    = string
  default = "10.0.0.0/16"
}