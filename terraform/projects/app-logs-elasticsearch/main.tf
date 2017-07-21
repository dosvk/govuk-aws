# == Manifest: projects::app-logs-elasticsearch
#
# Graphite node
#
# === Variables:
#
# aws_region
# stackname
# aws_environment
# ssh_public_key
# logs_elasticsearch_1_subnet
# logs_elasticsearch_2_subnet
# logs_elasticsearch_3_subnet
#
# === Outputs:
#

variable "aws_region" {
  type        = "string"
  description = "AWS region"
  default     = "eu-west-1"
}

variable "stackname" {
  type        = "string"
  description = "Stackname"
}

variable "aws_environment" {
  type        = "string"
  description = "AWS Environment"
}

variable "ssh_public_key" {
  type        = "string"
  description = "Default public key material"
}

variable "logs_elasticsearch_1_subnet" {
  type        = "string"
  description = "Name of the subnet to place the Graphite instance 1 and EBS volume"
}

variable "logs_elasticsearch_2_subnet" {
  type        = "string"
  description = "Name of the subnet to place the Graphite instance 2 and EBS volume"
}

variable "logs_elasticsearch_3_subnet" {
  type        = "string"
  description = "Name of the subnet to place the Graphite instance 3 and EBS volume"
}

# Resources
# --------------------------------------------------------------
terraform {
  backend          "s3"             {}
  required_version = "= 0.9.10"
}

provider "aws" {
  region = "${var.aws_region}"
}

resource "aws_elb" "logs_elasticsearch_elb" {
  name            = "${var.stackname}-logs-elasticsearch"
  subnets         = ["${data.terraform_remote_state.infra_networking.private_subnet_ids}"]
  security_groups = ["${data.terraform_remote_state.infra_security_groups.sg_logs-elasticsearch_elb_id}"]
  internal        = "true"

  listener {
    instance_port     = 9200
    instance_protocol = "tcp"
    lb_port           = 9200
    lb_protocol       = "tcp"
  }

  health_check {
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 3

    target   = "TCP:9200"
    interval = 30
  }

  cross_zone_load_balancing   = true
  idle_timeout                = 400
  connection_draining         = true
  connection_draining_timeout = 400

  tags = "${map("Name", "${var.stackname}-logs-elasticsearch", "Project", var.stackname, "aws_environment", var.aws_environment, "aws_migration", "logs_elasticsearch")}"
}

resource "aws_route53_record" "service_record" {
  zone_id = "${data.terraform_remote_state.infra_stack_dns_zones.internal_zone_id}"
  name    = "logs-elasticsearch.${data.terraform_remote_state.infra_stack_dns_zones.internal_domain_name}"
  type    = "A"

  alias {
    name                   = "${aws_elb.logs_elasticsearch_elb.dns_name}"
    zone_id                = "${aws_elb.logs_elasticsearch_elb.zone_id}"
    evaluate_target_health = true
  }
}

resource "aws_key_pair" "logs_elasticsearch_key" {
  key_name   = "${var.stackname}-logs-elasticsearch"
  public_key = "${var.ssh_public_key}"
}

# Instance 1
module "logs-elasticsearch-1" {
  source                        = "../../modules/aws/node_group"
  name                          = "${var.stackname}-logs-elasticsearch-1"
  vpc_id                        = "${data.terraform_remote_state.infra_vpc.vpc_id}"
  default_tags                  = "${map("Project", var.stackname, "aws_stackname", var.stackname, "aws_environment", var.aws_environment, "aws_migration", "logs_elasticsearch", "aws_hostname", "logs-elasticsearch-1")}"
  instance_subnet_ids           = "${matchkeys(values(data.terraform_remote_state.infra_networking.private_subnet_names_ids_map), keys(data.terraform_remote_state.infra_networking.private_subnet_names_ids_map), list(var.logs_elasticsearch_1_subnet))}"
  instance_security_group_ids   = ["${data.terraform_remote_state.infra_security_groups.sg_logs-elasticsearch_id}", "${data.terraform_remote_state.infra_security_groups.sg_management_id}"]
  instance_type                 = "t2.medium"
  create_instance_key           = false
  instance_key_name             = "${var.stackname}-logs-elasticsearch"
  instance_additional_user_data = "${join("\n", null_resource.user_data.*.triggers.snippet)}"
  instance_elb_ids              = ["${aws_elb.logs_elasticsearch_elb.id}"]
  root_block_device_volume_size = "20"
}

resource "aws_ebs_volume" "logs-elasticsearch-1" {
  availability_zone = "${lookup(data.terraform_remote_state.infra_networking.private_subnet_names_azs_map, var.logs_elasticsearch_1_subnet)}"
  size              = 100
  type              = "gp2"

  tags {
    Name            = "${var.stackname}-logs-elasticsearch-1"
    Project         = "${var.stackname}"
    aws_stackname   = "${var.stackname}"
    aws_environment = "${var.aws_environment}"
    aws_migration   = "logs_elasticsearch"
    aws_hostname    = "logs-elasticsearch-1"
  }
}

# TODO: Instance 2 and 3

resource "aws_iam_policy" "logs_elasticsearch_iam_policy" {
  name   = "${var.stackname}-logs-elasticsearch-additional"
  path   = "/"
  policy = "${file("${path.module}/additional_policy.json")}"
}

resource "aws_iam_role_policy_attachment" "logs_elasticsearch_1_iam_role_policy_attachment" {
  role       = "${module.logs-elasticsearch-1.instance_iam_role_name}"
  policy_arn = "${aws_iam_policy.logs_elasticsearch_iam_policy.arn}"
}

#resource "aws_iam_role_policy_attachment" "logs_elasticsearch_2_iam_role_policy_attachment" {
#  role       = "${module.logs-elasticsearch-2.instance_iam_role_name}"
#  policy_arn = "${aws_iam_policy.logs_elasticsearch_iam_policy.arn}"
#}
#
#resource "aws_iam_role_policy_attachment" "logs_elasticsearch_3_iam_role_policy_attachment" {
#  role       = "${module.logs-elasticsearch-3.instance_iam_role_name}"
#  policy_arn = "${aws_iam_policy.logs_elasticsearch_iam_policy.arn}"
#}

# Outputs
# --------------------------------------------------------------

output "service_dns_name" {
  value       = "${aws_route53_record.service_record.fqdn}"
  description = "DNS name to access the Logs Elasticsearch internal service"
}

output "logs_elasticsearch_elb_dns_name" {
  value       = "${aws_elb.logs_elasticsearch_elb.dns_name}"
  description = "DNS name to access the Logs Elasticsearch ELB"
}