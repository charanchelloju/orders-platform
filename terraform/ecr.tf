locals {
  services = ["order-service", "payment-service", "inventory-service", "notification-service"]
}

resource "aws_ecr_repository" "service" {
  for_each = toset(local.services)

  name                 = each.key
  image_tag_mutability = "MUTABLE"
  force_delete         = true                  # demo only

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Project = var.project
  }
}

resource "aws_ecr_lifecycle_policy" "service" {
  for_each   = aws_ecr_repository.service
  repository = each.value.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
