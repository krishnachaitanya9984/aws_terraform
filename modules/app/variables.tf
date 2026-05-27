variable "project_name"         { type = string }
variable "environment"          { type = string }
variable "vpc_id"               { type = string }
variable "private_app_subnet_ids" { type = list(string) }
variable "alb_sg_id"            { type = string }
variable "target_group_arn"     { type = string }
variable "instance_type"        { type = string }