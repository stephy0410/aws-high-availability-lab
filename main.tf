# Latest Amazon Linux 2023 AMI (x86_64), resolved from the public SSM parameter
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Default VPC in the region
data "aws_vpc" "default" {
  default = true
}

# Default subnets (one per AZ) inside the default VPC
data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

# Your current public IP, used to lock down SSH ingress
data "http" "myip" {
  url = "https://checkip.amazonaws.com/"
}

locals {
  ssh_cidr = var.allowed_ssh_cidr != null ? var.allowed_ssh_cidr : "${trimspace(data.http.myip.response_body)}/32"

  # Deterministic ordering so subnet placement doesn't shuffle between applies
  subnet_ids = sort(data.aws_subnets.default.ids)
}

# Brand-new EC2 key pair, built from a local SSH public key
resource "aws_key_pair" "lab" {
  key_name   = var.key_pair_name
  public_key = file(pathexpand(var.public_key_path))
}

# --- Security groups ---

resource "aws_security_group" "alb" {
  name        = "${var.instance_name}-alb-sg"
  description = "Internet-facing: allow HTTP+HTTPS in, all egress"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-alb-sg"
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.instance_name}-sg"
  description = "Allow HTTP only from the ALB, SSH from a single CIDR, all egress"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [local.ssh_cidr]
  }

  ingress {
    description     = "HTTP from ALB"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.instance_name}-sg"
  }
}

# --- Self-signed TLS certificate, imported into ACM ---
# No public domain is available in this Learner Lab account, so this generates
# a self-signed cert and imports it into ACM (free, no Route53/domain purchase
# needed) for the ALB's HTTPS listener. Browsers/curl will flag it as untrusted
# (expected) but the traffic is real end-to-end TLS.

resource "tls_private_key" "self" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self" {
  private_key_pem = tls_private_key.self.private_key_pem

  subject {
    common_name  = "${var.instance_name}.local"
    organization = "SD Lab03"
  }

  validity_period_hours = 8760 # 1 year
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self" {
  private_key      = tls_private_key.self.private_key_pem
  certificate_body = tls_self_signed_cert.self.cert_pem

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.instance_name}-self-signed"
  }
}

# --- Launch template used by the Auto Scaling Group ---

resource "aws_launch_template" "web" {
  name_prefix   = "${var.instance_name}-lt-"
  image_id      = data.aws_ssm_parameter.al2023.value
  instance_type = var.instance_type
  key_name      = aws_key_pair.lab.key_name

  vpc_security_group_ids = [aws_security_group.ec2.id]

  user_data = base64encode(file("${path.module}/user_data.sh"))

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size
      encrypted             = true
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.instance_name}-asg"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.instance_name}-asg"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Application Load Balancer ---

resource "aws_lb" "this" {
  name               = "${var.instance_name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids

  tags = {
    Name = "${var.instance_name}-alb"
  }
}

resource "aws_lb_target_group" "app" {
  name     = "${var.instance_name}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  load_balancing_algorithm_type = "round_robin"
  deregistration_delay          = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.instance_name}-tg"
  }
}

# HTTP listener: redirect everything to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS listener: terminate TLS with the self-signed ACM cert, forward round robin
# to whichever instances the ASG currently has registered.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.self.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# --- Auto Scaling Group: elastic, 1-3 EC2 instances behind the ALB ---

resource "aws_autoscaling_group" "web" {
  name                = "${var.instance_name}-asg"
  vpc_zone_identifier = local.subnet_ids
  target_group_arns   = [aws_lb_target_group.app.arn]

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  health_check_type         = "ELB"
  health_check_grace_period = 60

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.instance_name}-asg"
    propagate_at_launch = true
  }

  lifecycle {
    create_before_destroy = true
  }
}

# --- Elasticity: scale out on high CPU, scale back in on low CPU ---
# Together these bring the group up to max_size (3) under load and settle it
# back down to min_size (1) once load disappears - one instance at a time,
# gated by the cooldowns in variables.tf.

resource "aws_autoscaling_policy" "scale_out" {
  name                   = "${var.instance_name}-scale-out"
  autoscaling_group_name = aws_autoscaling_group.web.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = 1
  cooldown               = var.scale_out_cooldown
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.instance_name}-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_high_threshold
  alarm_description   = "Average CPU across the ASG > ${var.cpu_high_threshold}% for 2 minutes -> scale out"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_out.arn]
}

resource "aws_autoscaling_policy" "scale_in" {
  name                   = "${var.instance_name}-scale-in"
  autoscaling_group_name = aws_autoscaling_group.web.name
  adjustment_type        = "ChangeInCapacity"
  scaling_adjustment     = -1
  cooldown               = var.scale_in_cooldown
}

resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "${var.instance_name}-cpu-low"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_low_threshold
  alarm_description   = "Average CPU across the ASG < ${var.cpu_low_threshold}% for 3 minutes -> scale in, down to min_size"

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_autoscaling_policy.scale_in.arn]
}
