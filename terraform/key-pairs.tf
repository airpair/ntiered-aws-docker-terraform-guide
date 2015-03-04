resource "aws_key_pair" "deployer" {
  key_name   = "deployer-airpair-example" 
  public_key = "${file(\"ssh/insecure-deployer.pub\")}"
}

