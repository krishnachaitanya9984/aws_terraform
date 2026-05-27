# Three-Tier AWS Architecture with Terraform

A production-ready, modular three-tier web application infrastructure on AWS, built with Terraform. Deploys a fully isolated VPC with public and private subnets, an Application Load Balancer, an Auto Scaling Group of EC2 instances, and an RDS MySQL database — all wired together with least-privilege security groups.

---

## Architecture overview

```
                        Internet
                           │
                    ┌──────▼──────┐
                    │     ALB     │  ← public subnets (port 80)
                    └──────┬──────┘
                           │
            ┌──────────────▼──────────────┐
            │                             │
     ┌──────▼──────┐               ┌──────▼──────┐
     │  EC2 (1a)   │               │  EC2 (1b)   │  ← private app subnets
     └──────┬──────┘               └──────┬──────┘
            │                             │
            └──────────────┬──────────────┘
                           │
                    ┌──────▼──────┐
                    │  RDS MySQL  │  ← private DB subnets
                    └─────────────┘
```

### Traffic flow

1. User hits the ALB DNS name on port 80
2. ALB forwards the request to a healthy EC2 instance (round-robin)
3. EC2 instance processes the request and queries RDS if needed
4. RDS is only reachable from EC2 — never from the internet

### Security group chain

```
Internet → ALB SG (0.0.0.0/0:80) → App SG (alb-sg:80) → DB SG (app-sg:3306)
```

Each tier only accepts traffic from the tier directly above it. The database is never exposed to the internet under any circumstances.

---

## Project structure

```
aws-terraform/
│
├── main.tf                    # Root module — calls all child modules
├── variables.tf               # Input variable declarations
├── outputs.tf                 # Root outputs (ALB DNS, DB endpoint)
├── providers.tf               # AWS provider + Terraform version config
├── terraform.tfvars           # Variable values (keep out of git)
├── .gitignore
│
└── modules/
    ├── networking/            # Tier 0: VPC foundation
    │   ├── main.tf            # VPC, subnets, IGW, NAT, route tables
    │   ├── variables.tf       # Inputs: project_name, vpc_cidr, azs
    │   └── outputs.tf         # Outputs: vpc_id, subnet_ids
    │
    ├── web/                   # Tier 1: Load balancer layer
    │   ├── main.tf            # ALB, target group, listener, SG
    │   ├── variables.tf       # Inputs: vpc_id, public_subnet_ids
    │   └── outputs.tf         # Outputs: alb_dns_name, alb_sg_id, tg_arn
    │
    ├── app/                   # Tier 2: Application layer
    │   ├── main.tf            # Launch template, ASG, scaling policy, SG
    │   ├── variables.tf       # Inputs: vpc_id, subnets, alb_sg_id, tg_arn
    │   └── outputs.tf         # Outputs: app_sg_id, asg_name
    │
    └── database/              # Tier 3: Data layer
        ├── main.tf            # RDS MySQL, subnet group, SG
        ├── variables.tf       # Inputs: vpc_id, subnets, app_sg_id, creds
        └── outputs.tf         # Outputs: db_endpoint, db_name
```

---

## File roles explained

### `variables.tf` vs `terraform.tfvars`

These two files are often confused but serve completely different purposes:

| File | Role | Analogy |
|---|---|---|
| `variables.tf` | Declares that a variable *exists*, its type, and an optional default | Function signature / parameter declaration |
| `terraform.tfvars` | Supplies the actual *values* for those variables | Function call with arguments |

```hcl
# variables.tf — declaration only
variable "environment" {
  type    = string
  default = "dev"
}

# terraform.tfvars — actual value
environment = "prod"
```

The real power of this separation is environment-specific deployments:

```bash
terraform apply -var-file=dev.tfvars      # deploy dev
terraform apply -var-file=staging.tfvars  # deploy staging
terraform apply -var-file=prod.tfvars     # deploy prod
```

Same Terraform code, different values per environment.

### Why each module has three files

Every module works like a function in programming:

- **`variables.tf`** — the function's input parameters. Declares what data the module needs from the outside world. Nothing is hardcoded; everything is parameterized so the module is reusable.

- **`main.tf`** — the function body. Contains all the `resource` and `data` blocks that actually create infrastructure. This is where the work happens.

- **`outputs.tf`** — the function's return values. Exposes specific attributes of created resources so other modules or the root can reference them. Without outputs, modules are black boxes.

```
root main.tf
    │
    ├── module "networking"
    │       variables.tf ← receives: vpc_cidr, azs
    │       main.tf      ← creates:  VPC, subnets, IGW, NAT
    │       outputs.tf   → exposes:  vpc_id, subnet_ids
    │
    ├── module "web"
    │       variables.tf ← receives: vpc_id, public_subnet_ids  (from networking outputs)
    │       main.tf      ← creates:  ALB, target group, listener
    │       outputs.tf   → exposes:  alb_dns_name, alb_sg_id, target_group_arn
    │
    ├── module "app"
    │       variables.tf ← receives: vpc_id, private_subnets, alb_sg_id, tg_arn
    │       main.tf      ← creates:  launch template, ASG, scaling policy
    │       outputs.tf   → exposes:  app_sg_id, asg_name
    │
    └── module "database"
            variables.tf ← receives: vpc_id, private_db_subnets, app_sg_id, creds
            main.tf      ← creates:  RDS instance, subnet group
            outputs.tf   → exposes:  db_endpoint, db_name
```

---

## Module details

### `modules/networking` — VPC foundation

Everything else depends on this module. It must be created first.

| Resource | Purpose |
|---|---|
| `aws_vpc` | The private network boundary for all resources |
| `aws_subnet` (public) | Where ALB lives — has direct internet access |
| `aws_subnet` (private_app) | Where EC2 lives — no inbound internet access |
| `aws_subnet` (private_db) | Where RDS lives — most isolated tier |
| `aws_internet_gateway` | Gives public subnets a route to the internet |
| `aws_eip` + `aws_nat_gateway` | Gives private instances outbound internet (for updates) without inbound exposure |
| `aws_route_table` (public) | Routes `0.0.0.0/0` → Internet Gateway |
| `aws_route_table` (private) | Routes `0.0.0.0/0` → NAT Gateway |
| `aws_route_table_association` | Binds each subnet to its route table |

**Subnet CIDR allocation** (using `cidrsubnet`):

```
VPC: 10.0.0.0/16
  Public subnets:      10.0.0.0/24, 10.0.1.0/24
  Private app subnets: 10.0.10.0/24, 10.0.11.0/24
  Private DB subnets:  10.0.20.0/24, 10.0.21.0/24
```

---

### `modules/web` — Load balancer layer (Tier 1)

The only tier with a public-facing DNS name. Users never talk directly to EC2.

| Resource | Purpose |
|---|---|
| `aws_security_group` (alb) | Allows port 80 inbound from `0.0.0.0/0` |
| `aws_lb` | The Application Load Balancer itself |
| `aws_lb_target_group` | The pool of EC2 instances to route traffic to |
| `aws_lb_listener` | Rule: port 80 → forward to target group |

The ALB health check polls `/` on each EC2 instance every 30 seconds. If an instance fails 3 consecutive checks it is marked unhealthy and removed from rotation.

---

### `modules/app` — Application layer (Tier 2)

Runs the actual application. The ASG ensures high availability and automatic recovery.

| Resource | Purpose |
|---|---|
| `aws_security_group` (app) | Allows port 80 only from the ALB security group |
| `data.aws_ami` | Looks up the latest Amazon Linux 2 AMI automatically |
| `aws_launch_template` | Blueprint for EC2 instances: AMI, type, SG, bootstrap script |
| `aws_autoscaling_group` | Maintains desired instances across AZs, replaces unhealthy ones |
| `aws_autoscaling_policy` | Scales out by 1 instance when CPU > 70% |

**Key design decisions:**
- `associate_public_ip_address = false` — EC2 instances have no public IP, reachable only via ALB
- `$$` in `user_data` heredoc — escapes Terraform interpolation so `$(hostname)` runs on the EC2 instance, not during `terraform apply`
- `health_check_type = "ELB"` — ASG uses ALB health checks, not just EC2 status checks

---

### `modules/database` — Data layer (Tier 3)

Most isolated tier. Unreachable from the internet or the ALB — only the app tier can connect.

| Resource | Purpose |
|---|---|
| `aws_security_group` (db) | Allows port 3306 only from the app security group |
| `aws_db_subnet_group` | Tells RDS which private subnets to use |
| `aws_db_instance` | MySQL 8.0 on db.t3.micro with 20GB storage |

**Settings for dev (change for production):**

| Setting | Dev value | Prod recommendation |
|---|---|---|
| `multi_az` | `false` | `true` |
| `skip_final_snapshot` | `true` | `false` |
| `deletion_protection` | `false` | `true` |
| `instance_class` | `db.t3.micro` | `db.t3.medium` or higher |
| `allocated_storage` | `20` GB | `100`+ GB with autoscaling |

---

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/downloads) >= 1.7
- [AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html) >= 2.x
- AWS account with IAM user credentials (AdministratorAccess for learning)
- VS Code with the [HashiCorp Terraform extension](https://marketplace.visualstudio.com/items?itemName=HashiCorp.terraform)

---

## Setup

### 1. Configure AWS credentials

```bash
aws configure
# AWS Access Key ID:     AKIA...
# AWS Secret Access Key: your-secret
# Default region name:   ap-south-1
# Default output format: json
```

Verify:
```bash
aws sts get-caller-identity
```

### 2. Clone and configure

```bash
git clone <your-repo>
cd three-tier-aws
```

Edit `terraform.tfvars` with your values:

```hcl
project_name       = "three-tier-app"
environment        = "dev"
region             = "ap-south-1"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ap-south-1a", "ap-south-1b"]
instance_type      = "t3.micro"
db_name            = "appdb"
db_username        = "admin"
db_password        = "YourSecurePassword123!"
```

---

## Usage

### Deploy

```bash
# Download the AWS provider plugin
terraform init

# Preview all resources that will be created
terraform plan

# Deploy (type 'yes' when prompted)
terraform apply
```

After apply completes, get your application URL:

```bash
terraform output alb_dns_name
```

Paste that URL in your browser. You should see **"Hello from ip-x-x-x-x"**.

### Tear down

```bash
terraform destroy
```

This removes all ~25 resources in the correct order. Always run this when done to avoid AWS charges.

---

## Variables reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `project_name` | string | `three-tier-app` | Prefix applied to all resource names |
| `environment` | string | `dev` | Environment name (dev/staging/prod) |
| `region` | string | `ap-south-1` | AWS region to deploy into |
| `vpc_cidr` | string | `10.0.0.0/16` | CIDR block for the VPC |
| `availability_zones` | list(string) | `["ap-south-1a", "ap-south-1b"]` | AZs to spread resources across |
| `instance_type` | string | `t3.micro` | EC2 instance type for app servers |
| `db_name` | string | `appdb` | Name of the MySQL database |
| `db_username` | string | `admin` | RDS master username |
| `db_password` | string | — | RDS master password (**sensitive**) |

---

## Outputs reference

| Output | Description |
|---|---|
| `alb_dns_name` | Public DNS of the Application Load Balancer — use this as your app URL |
| `db_endpoint` | RDS connection endpoint (sensitive — use `terraform output db_endpoint`) |

---

## Estimated AWS costs (ap-south-1)

| Resource | Type | Est. cost |
|---|---|---|
| NAT Gateway | — | ~$0.045/hr + data transfer |
| EC2 × 2 | t3.micro | ~$0.0116/hr each |
| RDS | db.t3.micro | ~$0.017/hr |
| ALB | — | ~$0.022/hr + LCU |
| **Total** | | **~$0.15/hr (~₹12/hr)** |

> Run `terraform destroy` when not in use to avoid charges.

---

## Common issues

**502 Bad Gateway from ALB**
EC2 instances are unhealthy. Check target group health in the AWS console (EC2 → Target Groups → Targets tab). Usually caused by Apache not starting — verify `user_data` ran correctly via `/var/log/cloud-init-output.log`.

**`$(hostname)` appearing literally in the page**
The `$` in the `user_data` heredoc was consumed by Terraform. Use `$$` to escape it: `echo "<h1>Hello from $$(hostname)</h1>"`.

**4 instances running instead of 2**
The ASG replaced unhealthy instances during a failed deploy. Run `terraform apply` again — Terraform will detect `desired_capacity = 2` and scale back down. Terminated instances remain visible in the console briefly.

**`Error: Reference to undeclared resource` in outputs.tf**
The corresponding `main.tf` in that module is missing or empty. Re-paste the full content and save.

---

## Next steps

- **HTTPS** — Add an ACM certificate and port 443 listener on the ALB
- **Remote state** — Store `terraform.tfstate` in S3 + DynamoDB for team use
- **Bastion host / SSM** — Enable SSH access into private EC2 instances
- **Multi-environment** — Add `dev.tfvars`, `staging.tfvars`, `prod.tfvars`
- **CloudWatch** — Add alarms for CPU, unhealthy host count, and RDS connections
- **WAF** — Attach AWS WAF to the ALB for basic DDoS and injection protection

---

## .gitignore

```
.terraform/
terraform.tfstate
terraform.tfstate.backup
*.tfvars
.terraform.lock.hcl
*.tfplan
```

---

*Infrastructure managed with [Terraform](https://www.terraform.io/) — HashiCorp AWS Provider ~5.0*
