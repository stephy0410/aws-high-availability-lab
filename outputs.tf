output "web_url" {
  description = "HTTPS URL of the load-balanced app (self-signed cert - browsers/curl will warn; use curl -k)"
  value       = "https://${aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.this.dns_name
}

output "autoscaling_group_name" {
  description = "Name of the Auto Scaling Group"
  value       = aws_autoscaling_group.web.name
}

output "allowed_ssh_cidr" {
  description = "CIDR allowed to reach port 22"
  value       = local.ssh_cidr
}

output "key_pair_name" {
  description = "Name of the EC2 key pair Terraform created"
  value       = aws_key_pair.lab.key_name
}

output "list_current_instances_cmd" {
  description = "Run this to see how many instances the ASG currently has (1 at rest, up to 3 under load)"
  value       = "aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names ${aws_autoscaling_group.web.name} --profile ${var.profile} --region ${var.region} --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,Health:HealthStatus,State:LifecycleState}' --output table"
}

output "load_test_cmd" {
  description = "SSH into any current instance (see list_current_instances_cmd for its public IP) and run this to spike CPU and trigger scale-out"
  value       = "ssh -i ${var.private_key_path} ec2-user@<instance-public-ip> 'stress-ng --cpu $(nproc) --timeout 300s'"
}

output "round_robin_check_cmd" {
  description = "Run this a few times to see requests land on different instances once the group has scaled out"
  value       = "for i in $(seq 1 10); do curl -sk https://${aws_lb.this.dns_name}/api/whoami; echo; done"
}
