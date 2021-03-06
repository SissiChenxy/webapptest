data "aws_caller_identity" "current" { }

# security group for EC2 instances
resource "aws_security_group" "application" {
  vpc_id      = var.vpc_id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port = 8080
    to_port = 8080
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "application"
  }
}

# db security group
resource "aws_security_group" "database" {
  vpc_id = var.vpc_id

  ingress {
    from_port = 3306
    to_port = 3306
    protocol = "tcp"
    security_groups = ["${aws_security_group.application.id}"]
  }

  ingress {
    from_port = 5432
    to_port = 5432
    protocol = "tcp"
    security_groups = ["${aws_security_group.application.id}"]
  }

  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "database"
  }
}

# s3 bucket encrypt key
resource "aws_kms_key" "mykey" {
  description             = "This key is used to encrypt bucket objects"
  deletion_window_in_days = 10
}

# s3 bucket for image
resource "aws_s3_bucket" "bucket" {
  bucket = "webapp.${var.domain}"
  force_destroy = true
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = "${aws_kms_key.mykey.arn}"
        sse_algorithm     = "aws:kms"
      }
    }
  }

  lifecycle_rule {
    id      = "log"
    enabled = true

    prefix = "log/"

    tags = {
      "rule"      = "log"
      "autoclean" = "true"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA" # or "ONEZONE_IA"
    }

    transition {
      days          = 60
      storage_class = "GLACIER"
    }

    expiration {
      days = 90
    }
  }

  lifecycle_rule {
    id      = "tmp"
    prefix  = "tmp/"
    enabled = true

    expiration {
      date = "2019-12-15"
    }
  }
}

# s3 bucket for code deploy
resource "aws_s3_bucket" "codedeploy" {
  bucket = "codedeploy.${var.domain}"
  force_destroy = true
  acl    = "private"

  server_side_encryption_configuration {
    rule {
      apply_server_side_encryption_by_default {
        kms_master_key_id = "${aws_kms_key.mykey.arn}"
        sse_algorithm     = "aws:kms"
      }
    }
  }

  lifecycle_rule {
    id      = "cleanup"
    enabled = true

    prefix = "cleanup/"

    tags = {
      "rule"      = "cleanup"
      "autoclean" = "true"
    }

    expiration {
      days = 60
    }

    noncurrent_version_expiration {
      days = 1
    }
  }
}

# db subnet group
resource "aws_db_subnet_group" "default" {
  name = "db_sng"
  subnet_ids = ["${var.sb1_id}", var.sb2_id, "${var.sb3_id}"]

  tags = {
    Name = "db_sng"
  }
}

# db instance
resource "aws_db_instance" "csye6225" {
  identifier = "csye6225-fall2019"
  allocated_storage    = 20
  storage_type         = "gp2"
  engine               = "mysql"
  engine_version       = "5.7"
  instance_class       = "db.t2.micro"
  name                 = "csye6225"
  username             = "dbuser"
  password             = "A0zxcvasdf"
  parameter_group_name = "default.mysql5.7"
  publicly_accessible = false
  db_subnet_group_name = "${aws_db_subnet_group.default.name}"
  vpc_security_group_ids  = ["${aws_security_group.database.id}"]
  skip_final_snapshot = true
}

# DynamoDB Table
resource "aws_dynamodb_table" "csye6225" {
  name           = "csye6225"
  billing_mode   = "PROVISIONED"
  read_capacity  = 20
  write_capacity = 20
  hash_key       = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Name       = "csye6225"
    Enironment = "${var.profile}"
  }
}

# key pair
resource "aws_key_pair" "deployer" {
  key_name   = "pb_key"
  public_key = "${file(var.public_key_path)}"
}

# Iam role
resource "aws_iam_role" "codedeployec2role" {
  name        = "CodeDeployEC2ServiceRole"
  description = "Allows EC2 instances to call AWS services on your behalf."

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role" "codedeployrole" {
  name        = "CodeDeployServiceRole"
  description = "Allows EC2 instances to call AWS services such as auto calling on your behalf."

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "codedeploy.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

# Iam instance profile for code deploy ec2
resource "aws_iam_instance_profile" "codedeployec2" {
  name = "CodeDeployEC2ServiceRoleProfile"
  role = "${aws_iam_role.codedeployec2role.name}"
}

# CodeDeploy Applcation
resource "aws_codedeploy_app" "codedeployapp" {
  compute_platform = "Server"
  name = "csye6225-webapp"
}

# CodeDeploy Deployment Group
resource "aws_codedeploy_deployment_group" "codedeploygroup" {
  app_name              = "${aws_codedeploy_app.codedeployapp.name}"
  deployment_group_name = "csye6225-webapp-deployment"
  service_role_arn      = "${aws_iam_role.codedeployrole.arn}"

  ec2_tag_set {
    ec2_tag_filter {
      key   = "Name"
      type  = "KEY_AND_VALUE"
      value = "csye6225-ec2"
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}

# EC2 instance
resource "aws_instance" "web" {
  ami           = "${var.ami_id}"
  instance_type = "t2.micro"
  disable_api_termination = false

  # Our Security group to allow HTTP and SSH access
  vpc_security_group_ids = ["${aws_security_group.application.id}"]

  subnet_id = var.sb1_id
  key_name = "${aws_key_pair.deployer.id}"

  # Iam
  iam_instance_profile = "${aws_iam_instance_profile.codedeployec2.name}"

  root_block_device {
      volume_type = "gp2"
      volume_size = 20
  }

  ebs_block_device {
      device_name           = "/dev/sda1"
      delete_on_termination = true
  }

  depends_on = [aws_db_instance.csye6225]

  tags = {
    Name       = "csye6225-ec2"
    Enironment = "${var.profile}"
  }
}


# CodeDeploy-EC2-S3 policy
resource "aws_iam_policy" "policy1" {
  name        = "CodeDeploy-EC2-S3"
  description = "allows EC2 instances to read data from S3 buckets"

  policy = <<EOF
{
  "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "s3:Get*",
                "s3:List*"
            ],
            "Effect": "Allow",
            "Resource": [
                 "arn:aws:s3:::${aws_s3_bucket.codedeploy.bucket}",
                 "arn:aws:s3:::${aws_s3_bucket.codedeploy.bucket}/*"
            ]
        }
    ]
}
EOF
}

# CircleCI-Upload-To-S3
resource "aws_iam_policy" "policy2" {
  name        = "CircleCI-Upload-To-S3"
  description = "allows CircleCI to upload artifacts from latest successful build to dedicated S3 bucket used by code deploy"

  policy = <<EOF
{
  "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:PutObject"
            ],
            "Resource": [
                 "arn:aws:s3:::${aws_s3_bucket.codedeploy.bucket}",
                 "arn:aws:s3:::${aws_s3_bucket.codedeploy.bucket}/*"
            ]
        }
    ]
}
EOF
}

# CircleCI-Code-Deploy
resource "aws_iam_policy" "policy3" {
  name        = "CircleCI-Code-Deploy"
  description = "allows CircleCI to call CodeDeploy APIs to initiate application deployment on EC2 instances"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "codedeploy:RegisterApplicationRevision",
        "codedeploy:GetApplicationRevision"
      ],
      "Resource": [
        "arn:aws:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:application:application:csye6225-webapp"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codedeploy:CreateDeployment",
        "codedeploy:GetDeployment"
      ],
      "Resource": [
        "*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codedeploy:GetDeploymentConfig"
      ],
      "Resource": [
        "arn:aws:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:deploymentconfig:CodeDeployDefault.OneAtATime",
        "arn:aws:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:deploymentconfig:CodeDeployDefault.HalfAtATime",
        "arn:aws:codedeploy:${var.region}:${data.aws_caller_identity.current.account_id}:deploymentconfig:CodeDeployDefault.AllAtOnce"
      ]
    }
  ]
}
EOF
}

# circleci-ec2-ami
resource "aws_iam_policy" "policy4" {
  name        = "circleci-ec2-ami"
  description = "allows CircleCI to upload artifacts from latest successful build to dedicated S3 bucket used by code deploy"

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
      "Effect": "Allow",
      "Action" : [
        "ec2:AttachVolume",
        "ec2:AuthorizeSecurityGroupIngress",
        "ec2:CopyImage",
        "ec2:CreateImage",
        "ec2:CreateKeypair",
        "ec2:CreateSecurityGroup",
        "ec2:CreateSnapshot",
        "ec2:CreateTags",
        "ec2:CreateVolume",
        "ec2:DeleteKeyPair",
        "ec2:DeleteSecurityGroup",
        "ec2:DeleteSnapshot",
        "ec2:DeleteVolume",
        "ec2:DeregisterImage",
        "ec2:DescribeImageAttribute",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceStatus",
        "ec2:DescribeRegions",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSnapshots",
        "ec2:DescribeSubnets",
        "ec2:DescribeTags",
        "ec2:DescribeVolumes",
        "ec2:DetachVolume",
        "ec2:GetPasswordData",
        "ec2:ModifyImageAttribute",
        "ec2:ModifyInstanceAttribute",
        "ec2:ModifySnapshotAttribute",
        "ec2:RegisterImage",
        "ec2:RunInstances",
        "ec2:StopInstances",
        "ec2:TerminateInstances"
      ],
      "Resource" : "*"
  }]
}
EOF
}
