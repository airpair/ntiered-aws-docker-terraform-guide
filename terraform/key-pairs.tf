resource "aws_key_pair" "deployer" {
  key_name   = "deployer-meetup-example" 
  public_key = "${file(\"ssh/insecure-deployer.pub\")}"
}

