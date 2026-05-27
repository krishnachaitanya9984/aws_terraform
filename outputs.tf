output "alb_dns_name" {
  value       = module.web.alb_dns_name
  description = "Paste this URL in your browser to see the app"
}

output "db_endpoint" {
  value     = module.database.db_endpoint
  sensitive = true
}