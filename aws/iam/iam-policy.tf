
resource "aws_iam_policy" "admin-user" {
  name = "AdminUser"
  policy = file("iam-policy.json")
  
}