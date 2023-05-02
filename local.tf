resource "local_file" "pet" {
  filename = "./pet.txt"
  content = "We love pets!"
  file_permission = 700
}

resource "local_sensitive_file" "foo" {
  content  = "foo!"
  filename = "./foo.bar"
}

resource "random_pet" "my-pet" {
  length = 1
  prefix = "Mr"
  separator = "."
}

