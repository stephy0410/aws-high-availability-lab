variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile to use (AWS Academy Learner Lab credentials)"
  type        = string
  default     = "academy"
}

variable "instance_name" {
  description = "Name tag prefix for every resource in this lab"
  type        = string
  default     = "sd-lab03"
}

variable "instance_type" {
  description = "EC2 instance type (Learner Lab allows nano/micro/small/medium/large)"
  type        = string
  default     = "t3.micro"
}

variable "key_pair_name" {
  description = "Name of the EC2 key pair Terraform will create"
  type        = string
  default     = "sd-lab03-key"
}

variable "public_key_path" {
  description = "Path to the local SSH public key to register as the key pair"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "private_key_path" {
  description = "Path to the matching local private key, used only to build the ssh_command output"
  type        = string
  default     = "~/.ssh/id_ed25519"
}

variable "root_volume_size" {
  description = "Size of the root EBS volume in GiB"
  type        = number
  default     = 8
}

variable "allowed_ssh_cidr" {
  description = "CIDR allowed to SSH (port 22). If null, your current public IP is detected and used."
  type        = string
  default     = null
}

# --- Elasticity: Auto Scaling Group bounds ---

variable "min_size" {
  description = "Minimum (and steady-state) number of EC2 instances. The ASG always settles back here once CPU load drops."
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum number of EC2 instances the ASG is allowed to grow to under load"
  type        = number
  default     = 3
}

variable "desired_capacity" {
  description = "Desired capacity at creation time"
  type        = number
  default     = 1
}

# --- Elasticity: CPU thresholds that drive scale-out / scale-in ---

variable "cpu_high_threshold" {
  description = "Average CPU% across the ASG above which a scale-out (+1 instance) is triggered"
  type        = number
  default     = 60
}

variable "cpu_low_threshold" {
  description = "Average CPU% across the ASG below which a scale-in (-1 instance) is triggered"
  type        = number
  default     = 20
}

variable "scale_out_cooldown" {
  description = "Seconds to wait after a scale-out before another scaling activity is allowed"
  type        = number
  default     = 120
}

variable "scale_in_cooldown" {
  description = "Seconds to wait after a scale-in before another scaling activity is allowed"
  type        = number
  default     = 180
}
