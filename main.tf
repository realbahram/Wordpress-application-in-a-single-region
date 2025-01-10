resource "aws_iam_role" "app" {
  name               = "app"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachments_exclusive" "app" {
  role_name   = aws_iam_role.app.name
  policy_arns = [
    data.aws_iam_policy.ssm_managed.arn,
    data.aws_iam_policy.database.arn
  ]
}

resource "aws_iam_role" "web_hosting" {
  name               = "web_hosting"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

resource "aws_iam_role_policy_attachments_exclusive" "web_hosting" {
  role_name   = aws_iam_role.web_hosting.name
  policy_arns = [
    data.aws_iam_policy.ssm_managed.arn,
    data.aws_iam_policy.s3_ReadOnly.arn
  ]
}

resource "aws_iam_instance_profile" "app" {
  name = "app-profile"
  role = aws_iam_role.app.name
}

resource "aws_iam_instance_profile" "web_hosting" {
  name = "web-hosting-profile"
  role = aws_iam_role.web_hosting.name
}

# VPC
resource "aws_vpc" "default" {
  cidr_block           = local.vpc.cidr_block
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "${var.namespace}-vpc"
  }
}

resource "aws_subnet" "public" {
  for_each = { for index, az_name in local.vpc.azs : index => az_name }

  vpc_id                  = aws_vpc.default.id
  cidr_block              = cidrsubnet(aws_vpc.default.cidr_block, 8, (each.key + (length(local.vpc.azs) * 0)))
  availability_zone       = each.value
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.namespace}-subnet-public-${each.key}"
  }
}

resource "aws_subnet" "private" {
  for_each = { for index, az_name in local.vpc.azs : index => az_name }

  vpc_id            = aws_vpc.default.id
  cidr_block        = cidrsubnet(aws_vpc.default.cidr_block, 8, (each.key + (length(local.vpc.azs) * 1)))
  availability_zone = each.value

  tags = {
    Name = "${var.namespace}-subnet-private-${each.key}"
  }
}

resource "aws_subnet" "private_ingress" {
  for_each = { for index, az_name in local.vpc.azs : index => az_name }

  vpc_id            = aws_vpc.default.id
  cidr_block        = cidrsubnet(aws_vpc.default.cidr_block, 8, (each.key + (length(local.vpc.azs) * 2)))
  availability_zone = each.value

  tags = {
    Name = "${var.namespace}-subnet-private_ingress-${each.key}"
  }
}

resource "aws_internet_gateway" "default" {
  vpc_id = aws_vpc.default.id

  tags = {
    Name = "${var.namespace}-internet-gateway"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.default.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.default.id
  }

  tags = {
    Name = "${var.namespace}-route-table-public"
  }
}

resource "aws_route_table" "private_ingress" {
  count = length(aws_subnet.private_ingress)

  vpc_id = aws_vpc.default.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.default[count.index].id
  }

  tags = {
    Name = "${var.namespace}-route-table-private-ingress-${count.index}"
  }
}

resource "aws_main_route_table_association" "default" {
  vpc_id         = aws_vpc.default.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private_ingress" {
  count = length(aws_subnet.private_ingress)

  subnet_id      = aws_subnet.private_ingress[count.index].id
  route_table_id = aws_route_table.private_ingress[count.index].id
}

resource "aws_eip" "nat_gateway" {
  count = length(aws_subnet.public)

  tags = {
    Name = "${var.namespace}-private_ingress-nat-gateway-eip-${count.index}"
  }
}

resource "aws_nat_gateway" "default" {
  count = length(aws_subnet.public)

  connectivity_type = "public"
  subnet_id         = aws_subnet.public[count.index].id
  allocation_id     = aws_eip.nat_gateway[count.index].id
  depends_on        = [aws_internet_gateway.default]

  tags = {
    Name = "${var.namespace}-private_ingress-nat-gateway-${count.index}"
  }
}

# Security Groups
resource "aws_security_group" "nfs" {
  name_prefix = "${var.namespace}-nfs-"
  vpc_id      = aws_vpc.default.id

  ingress {
    description = "Allow any NFS traffic from private subnets"
    cidr_blocks = concat(values(aws_subnet.private)[*].cidr_block, values(aws_subnet.private_ingress)[*].cidr_block)
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
  }

  egress {
    description      = "Allow all outbound traffic"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
  }
}

resource "aws_security_group" "app" {
  name_prefix = "${var.namespace}-app-"
  vpc_id      = aws_vpc.default.id

  ingress {
    description = "Allow HTTPS from any IP"
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
  }

  ingress {
    description = "Allow HTTP from any IP"
    cidr_blocks = ["0.0.0.0/0"]
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
  }

  egress {
    description      = "Allow all outbound traffic"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
  }
}

resource "aws_security_group" "db" {
  name_prefix = "${var.namespace}-db-"
  vpc_id      = aws_vpc.default.id

  ingress {
    description = "Allow incoming traffic for MySQL"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = concat(values(aws_subnet.private)[*].cidr_block, values(aws_subnet.private_ingress)[*].cidr_block)
  }

  egress {
    description      = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

resource "aws_security_group" "any" {
  name_prefix = "${var.namespace}-any-"
  vpc_id      = aws_vpc.default.id

  ingress {
    description      = "Allow any incoming traffic "
    from_port        = 0
    to_port          = 0
    protocol         = -1
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  egress {
    description      = "Allow all outbound traffic"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }
}

# Create VPC endpoints
resource "aws_vpc_endpoint" "interface" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages", "secretsmanager"])

  vpc_id              = aws_vpc.default.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  subnet_ids         = values(aws_subnet.private_ingress)[*].id
  security_group_ids = [aws_security_group.any.id]

  tags = {
    Name = "${var.namespace}-endpoint-${each.key}"
  }
}

resource "aws_vpc_endpoint" "gateway" {
  for_each = toset(["s3"])

  vpc_id       = aws_vpc.default.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.${each.key}"

  tags = {
    Name = "${var.namespace}-endpoint-${each.key}"
  }
}

# RDS
resource "aws_db_subnet_group" "mission_db_group" {
  name       = "${var.namespace}-db-group"
  subnet_ids = values(aws_subnet.private)[*].id

  tags = {
    Name = "${var.namespace}-db-group"
  }
}

resource "random_password" "default" {
  length           = 25
  special          = false
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

resource "aws_secretsmanager_secret" "db" {
  name_prefix             = "${var.namespace}-secret-db-"
  description             = "Password to the RDS"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id     = aws_secretsmanager_secret.db.id
  secret_string = random_password.default.result
}

resource "aws_db_instance" "wp_mysql" {
  identifier = "${var.namespace}-db"

  allocated_storage      = 20
  engine                 = local.rds.engine
  engine_version         = local.rds.engine_version
  instance_class         = local.rds.instance_class
  db_name                = local.rds.db_name
  username               = local.rds.username
  password               = aws_secretsmanager_secret_version.db.secret_string
  db_subnet_group_name   = aws_db_subnet_group.mission_db_group.name
  vpc_security_group_ids = [aws_security_group.db.id]
  multi_az               = true
  skip_final_snapshot    = true

  tags = {
    Name = "${var.namespace}-db"
  }
}

# EFS
resource "aws_efs_file_system" "mission_app" {
  creation_token = "${var.namespace}-efs"
  encrypted      = true

  tags = {
    Name = "${var.namespace}-efs"
  }
}

resource "aws_efs_mount_target" "mission_app_targets" {
  count = length(local.vpc.azs)

  file_system_id  = aws_efs_file_system.mission_app.id
  subnet_id       = aws_subnet.private_ingress[count.index].id
  security_groups = [aws_security_group.nfs.id]
}

resource "aws_instance" "staging_app" {

  lifecycle {
    prevent_destroy = false
    ignore_changes  = [iam_instance_profile, tags, tags_all]
  }

  ami                         = data.aws_ami.linux.image_id
  instance_type               = local.vm.instance_type
  subnet_id                   = aws_subnet.private_ingress[0].id
  user_data_replace_on_change = true

  user_data = templatefile("${path.module}/userdata/staging-efs.sh", {
    region        = data.aws_region.current.name,
    efs_id        = aws_efs_file_system.mission_app.id
    db_name       = aws_db_instance.wp_mysql.db_name
    db_username   = aws_db_instance.wp_mysql.username
    db_password   = aws_db_instance.wp_mysql.password
    db_host       = aws_db_instance.wp_mysql.address
    DOMAIN_NAME   = aws_cloudfront_distribution.mission_app.domain_name
    demo_username = local.demo.admin.username
    demo_password = local.demo.admin.password
    demo_email    = local.demo.admin.email
  })

  iam_instance_profile   = aws_iam_instance_profile.app.name
  availability_zone      = data.aws_availability_zones.available.names[0]
  vpc_security_group_ids = [aws_security_group.app.id]

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  root_block_device {
    delete_on_termination = true
    encrypted             = true
  }

  tags = {
    Name = format("${var.namespace}-staging_app-%s", element(data.aws_availability_zones.available.names, 0))
  }

  depends_on = [aws_s3_object.mission_app-private_key, aws_s3_object.mission_app-public_key]
}

resource "aws_ami_copy" "mission_app_ami" {
  name              = "Amazon Linux 2 Image"
  description       = "A copy of ${data.aws_ami.linux.image_id} - ${data.aws_ami.linux.description}"
  source_ami_id     = data.aws_ami.linux.image_id
  source_ami_region = data.aws_region.current.name

  tags = {
    Name               = "${var.namespace}-ami"
    Description        = data.aws_ami.linux.description
    "Creation Date"    = data.aws_ami.linux.creation_date
    "Deprecation Time" = data.aws_ami.linux.deprecation_time
  }
}

# Application Load Balancer
resource "aws_lb" "mission_app" {
  name               = "${var.namespace}-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = values(aws_subnet.private)[*].id

  tags = {
    Name = "${var.namespace}-lb"
  }

  security_groups = [aws_security_group.app.id]
}

# Launch configuration
resource "aws_launch_template" "mission_app_lc" {
  name_prefix = "${var.namespace}-mission_app_iac_lc-"
  image_id    = aws_ami_copy.mission_app_ami.id

  instance_requirements {
    memory_mib {
      min = local.vm.instance_requirements.memory_mib.min
    }
    vcpu_count {
      min = local.vm.instance_requirements.vcpu_count.min
    }

    allowed_instance_types = ["m*"]
    instance_generations   = local.vm.instance_requirements.instance_generations
  }

  ebs_optimized          = true
  vpc_security_group_ids = [aws_security_group.app.id]

  iam_instance_profile {
    name = aws_iam_instance_profile.web_hosting.name
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      delete_on_termination = true
      encrypted             = true
    }
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
    http_tokens                 = "required"
    instance_metadata_tags      = "enabled"
  }

  user_data = base64encode(templatefile("${path.module}/userdata/staging-wordpress.sh", {
    region    = data.aws_region.current.name,
    efs_id    = aws_efs_file_system.mission_app.id,
    s3_bucket = aws_s3_bucket.mission_app.bucket
  }))

  update_default_version = true
}

resource "aws_autoscaling_group" "mission_app_asg" {
  name     = "${var.namespace}-asg-mission_app"
  min_size = 2
  max_size = 8

  vpc_zone_identifier = values(aws_subnet.private_ingress)[*].id
  target_group_arns   = [aws_lb_target_group.mission_app.arn]

  mixed_instances_policy {
    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.mission_app_lc.id
        version            = "$Latest"
      }
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  tag {
    key                 = "Name"
    value               = "${var.namespace}-asg-mission_app"
    propagate_at_launch = true
  }

  depends_on = [aws_instance.staging_app, aws_db_instance.wp_mysql]
}

resource "aws_autoscaling_policy" "mission_app_scale_out_policy" {
  name                   = "${var.namespace}-out-policy"
  scaling_adjustment     = 4
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 300
  autoscaling_group_name = aws_autoscaling_group.mission_app_asg.name
}

# ASG Cloudwatch policy
resource "aws_cloudwatch_metric_alarm" "mission_app_scale_out_alarm" {
  alarm_name          = "${var.namespace}-out-alarm"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "30"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mission_app_asg.name
  }

  alarm_description = "This metric monitors ec2 cpu utilization for Mission App ASG"
  alarm_actions     = [aws_autoscaling_policy.mission_app_scale_out_policy.arn]
}

resource "aws_autoscaling_policy" "mission_app_scale_in_policy" {
  name                   = "${var.namespace}-in-policy"
  scaling_adjustment     = -1
  adjustment_type        = "ChangeInCapacity"
  cooldown               = 180
  autoscaling_group_name = aws_autoscaling_group.mission_app_asg.name
}

# ASG Cloudwatch policy
resource "aws_cloudwatch_metric_alarm" "mission_app_scale_in_alarm" {
  alarm_name          = "${var.namespace}-in-alarm"
  comparison_operator = "LessThanOrEqualToThreshold"
  evaluation_periods  = "2"
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = "60"
  statistic           = "Average"
  threshold           = "20"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.mission_app_asg.name
  }

  alarm_description = "This metric monitors ec2 cpu utilization for Mission App ASG"
  alarm_actions     = [aws_autoscaling_policy.mission_app_scale_in_policy.arn]
}

resource "aws_lb_target_group" "mission_app" {
  name     = "${var.namespace}-lb-tg"
  port     = 443
  protocol = "HTTPS"
  vpc_id   = aws_vpc.default.id

  stickiness {
    type            = "lb_cookie"
    cookie_duration = 1800
    enabled         = true
  }

  health_check {
    healthy_threshold   = 3
    unhealthy_threshold = 10
    timeout             = 5
    interval            = 10
    path                = "/"
    port                = 443
    protocol            = "HTTPS"
  }
}

resource "aws_lb_listener" "mission_app_http" {
  load_balancer_arn = aws_lb.mission_app.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mission_app.arn
  }
}

resource "aws_lb_listener_rule" "redirect_cloudfront_to_http" {
  listener_arn = aws_lb_listener.mission_app_http.arn
  priority     = 100

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mission_app.arn
  }

  condition {
    http_header {
      http_header_name = "X-Request"
      values           = [aws_lb.mission_app.dns_name]
    }
  }
}

resource "aws_lb_listener_rule" "redirect_http_to_https" {
  listener_arn = aws_lb_listener.mission_app_http.arn
  priority     = 200

  action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }

  condition {
    host_header {
      values = [aws_lb.mission_app.dns_name]
    }
  }
}

# Certificates
resource "tls_private_key" "mission_app" {
  algorithm = "RSA"
}

resource "tls_self_signed_cert" "mission_app" {
  private_key_pem = tls_private_key.mission_app.private_key_pem

  validity_period_hours = 8760

  # Generate a new certificate if Terraform is run within three
  # hours of the certificate's expiration time.
  early_renewal_hours = 3

  # Reasonable set of uses for a server SSL certificate.
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [
    aws_lb.mission_app.dns_name
  ]

  subject {
    common_name         = aws_lb.mission_app.dns_name
    organization        = "Amazon Web Services"
    organizational_unit = "WWPS ProServe"
    country             = "USA"
    locality            = "San Diego"
  }
}

resource "aws_acm_certificate" "mission_app_private" {
  private_key      = tls_private_key.mission_app.private_key_pem
  certificate_body = tls_self_signed_cert.mission_app.cert_pem
}

resource "aws_s3_bucket" "mission_app" {
  bucket_prefix = "${var.namespace}-mission-app-"

  tags = {
    Description = "Used to store items"
  }
}

resource "aws_s3_bucket_public_access_block" "mission_app" {
  bucket = aws_s3_bucket.mission_app.bucket

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "mission_app-private_key" {
  bucket = aws_s3_bucket.mission_app.bucket

  key     = "server.key"
  content = tls_private_key.mission_app.private_key_pem
}

resource "aws_s3_object" "mission_app-public_key" {
  bucket = aws_s3_bucket.mission_app.bucket

  key     = "server.crt"
  content = tls_self_signed_cert.mission_app.cert_pem
}

# Application Load Balancer (finishing touch)
resource "aws_lb_listener" "mission_app_https" {
  load_balancer_arn = aws_lb.mission_app.arn
  port              = "443"
  protocol          = "HTTPS"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mission_app.arn
  }

  certificate_arn = aws_acm_certificate.mission_app_private.arn
}

resource "aws_cloudfront_distribution" "mission_app" {
  enabled = true
  comment = "${var.namespace} - frontend site for mission app"

  origin {
    domain_name = aws_lb.mission_app.dns_name
    origin_id   = aws_lb.mission_app.dns_name
    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }

    custom_header {
      name  = "X-Request"
      value = aws_lb.mission_app.dns_name
    }
  }

  default_cache_behavior {
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD", "OPTIONS"]
    target_origin_id       = aws_lb.mission_app.dns_name
    viewer_protocol_policy = "redirect-to-https"
    cache_policy_id        = aws_cloudfront_cache_policy.default.id
  }

  # https://en.wikipedia.org/wiki/List_of_ISO_3166_country_codes
  restrictions {
    geo_restriction {
      restriction_type = "none"
      locations        = []
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_cloudfront_cache_policy" "default" {
  name        = "${var.namespace}-default-policy"
  comment     = "Default Policy"
  default_ttl = 50
  max_ttl     = 100
  min_ttl     = 1

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "all"
    }
    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["X-Request"]
      }
    }
    query_strings_config {
      query_string_behavior = "all"
    }
  }
}