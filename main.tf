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