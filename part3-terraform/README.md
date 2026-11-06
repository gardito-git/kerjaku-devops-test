# KerjaKu - DevOps Engineer Technical Assessment: Answers

## Part 3 - Infrastructure as code (15 points)

A developer wrote this Terraform to move the web servers into an Auto Scaling Group. It is
waiting for your review.
---
### File E - web.tf
```hcl
resource "aws_security_group" "web" {
  name   = "web-sg"
  vpc_id = var.vpc_id

  ingress {
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_launch_template" "web" {
  name_prefix   = "kerjaku-web-"
  image_id      = "ami-0abc1234def567890"
  instance_type = "t3.medium"
  key_name      = "shared-team-key"
  vpc_security_group_ids = [aws_security_group.web.id]
  
  user_data = base64encode(<<-EOF
    #!/bin/bash
    export AWS_ACCESS_KEY_ID=AKIAEXAMPLE123456
    export AWS_SECRET_ACCESS_KEY=wJalrEXAMPLEKEY
    aws s3 cp s3://kerjaku-config/.env /var/www/kerjaku/.env
    docker run -d -p 3000:3000 kerjaku-app:latest
  EOF
  )
}

resource "aws_autoscaling_group" "web" {
  min_size            = 1
  max_size            = 10
  desired_capacity    = 1
  vpc_zone_identifier = [var.public_subnet_a]
  health_check_type   = "EC2"
  target_group_arns   = [var.alb_target_group_arn]
  
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
}
```
The team keeps Terraform state in a local terraform.tfstate file committed to Git.

### Questions
1. Write your code review: list each issue, its risk, and the fix. (8 pts)
2. Rewrite the security group and Auto Scaling Group blocks the way you would merge them. (4 pts)
3. What is wrong with how the team stores Terraform state, and what would you set up instead? (3 pts)