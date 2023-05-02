resource "random_uuid" "id1" {
   
}
resource "random_uuid" "id2" {
   
}

resource "random_integer" "order1" {
  min     = 1
  max     = 99999
 
}
resource "random_integer" "order2" {
  min     = 1
  max     = 222222
 
}