module "networking" {
  source             = "./modules/networking"
  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

module "web" {
  source            = "./modules/web"
  project_name      = var.project_name
  environment       = var.environment
  vpc_id            = module.networking.vpc_id
  public_subnet_ids = module.networking.public_subnet_ids
}

module "app" {
  source                = "./modules/app"
  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.networking.vpc_id
  private_app_subnet_ids = module.networking.private_app_subnet_ids
  alb_sg_id             = module.web.alb_sg_id
  target_group_arn      = module.web.target_group_arn
  instance_type         = var.instance_type
}

module "database" {
  source               = "./modules/database"
  project_name         = var.project_name
  environment          = var.environment
  vpc_id               = module.networking.vpc_id
  private_db_subnet_ids = module.networking.private_db_subnet_ids
  app_sg_id            = module.app.app_sg_id
  db_name              = var.db_name
  db_username          = var.db_username
  db_password          = var.db_password
}