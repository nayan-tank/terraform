resource "random_pet" "my-pet" {
    prefix = "Mr"
    separator = "."
    length = 1
  
}

resource "local_file" "pet" {
    filename = "./pet.txt"
    content = "My fav pat is ${random_pet.my-pet.id}"
  
}