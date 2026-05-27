output "app_sg_id"            { value = aws_security_group.app.id }
output "autoscaling_group_name" { value = aws_autoscaling_group.app.name }