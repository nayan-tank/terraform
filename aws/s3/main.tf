resource "aws_s3_bucket" "pixar-studios-2020" {
    bucket = "pixar-studios-2020"
}


resource "aws_s3_bucket_object" "woody" {
    content = "/root/woody.jpg"
    key = "woody.jpg"
    bucket = aws_s3_bucket.pixar-studios-2020.id
  
}