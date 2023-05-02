resource "aws_iam_user" "admin" {
  name = "nayan"
  tags = {
    Description = "Hey, admin here"
  }
  
}