# ─── EventBridge cron rule for archive-orders Lambda ──────────────────────
# EventBridge cron is ALWAYS UTC. Sunday 3 AM UTC = low-traffic window.

resource "aws_cloudwatch_event_rule" "archive_orders" {
  name                = "${var.project}-archive-orders-schedule"
  description         = "Trigger archive-orders Lambda every Sunday at 3 AM UTC"
  schedule_expression = "cron(0 3 ? * SUN *)"
  state               = "ENABLED"
}

resource "aws_cloudwatch_event_target" "archive_orders" {
  rule = aws_cloudwatch_event_rule.archive_orders.name
  arn  = aws_lambda_function.archive_orders.arn
}

resource "aws_lambda_permission" "archive_orders_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.archive_orders.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.archive_orders.arn
}
