Data, a crucial part of any infrastructure, is particularly vulnerable while traveling over the Internet. Securing its transportation is a fundamental requirement for establishing a trusted network. 

While there are several transport level protocols available for encrypting the transmission, communicating privately in a closed network is the most common and efficient way to keep data secure.

I wrote this guide in an attempt to help the reader to build a closed private network on AWS and to establish a secure way to access network resources, using a trusted VPN.

Before we begin
---------------

This is a technical guide, best accessible to a reader with basic linux command line knowledge. The Audience this guide is intended for includes:
 
- Application developers with little or no systems administration experience, wanting to deploy applications on AWS
- System administrators with little or no experience with infrastructure automation, wanting to learn more
- Infrastructure automation engineers that want to explore cloud resource automation
- Anyone who wants to get a feel for the current state of cloud automation tooling

I kept the scope limited to building a private network and did not cover application and OS level security, which are equally important.

As you follow the various steps in this guide, you will be creating real AWS resources, which cost money. I did my best to keep the utilization footprint minimal, using the least possible configuration. I estimate less than hour to complete all the steps in this guide, at $0.079/hr.

By the end, to demonstrate the disposable nature of infrastructure-as-code, you will be destroying all infrastructure components that were created during the course of this tutorial.

I have uploaded the source code you will be writing to a [github repo](https://github.com/airpair/ntiered-aws-docker-terraform-guide/tree/edit/terraform), it is available for reference in case you feel lost.

Please have the below ready before we begin:

- AWS access and secret keys to an active AWS account.
- A Unix flavored workstation with internet connection; most commands will work on Windows with a shell emulator like Cygwin.

The Private Network
-------------------

During the course of this tutorial, we will be building a Virtual Private Cloud (VPC) on AWS along with a public-private subnet (sub-networks) pair. 

Instances in the private subnet cannot directly access the internet, making them an ideal for hosting critical resources such as application and database servers.

In the private subnet, we will be building two application server instances. In the future, the private subnet is where you  will host application support instances like database servers, cache servers, log hosts, build servers and configuration stores. Instances in the private subnet rely on a Network Address Translation (NAT) server, running in the public subnet for internet connectivity. 

All Instances in the public subnet can transmit inbound and outbound traffic to and from the internet. The routing resources such as load balancers, VPN and NAT servers reside in this subnet.

The NAT server we are building will also run an OpenVPN server. OpenVPN is a full-featured SSL VPN, which implements OSI layer 3 secure network extension using the industry standard SSL/TLS protocol. It provides an encrypted UDP encapsulated tunnel to connect with instances in the private network from your workstation.

In the later part of this guide, we will connect to the private network using via this VPN server and a compatible OpenVPN client. For a Mac, [Viscosity](https://www.sparklabs.com/viscosity) is a good commercial client; my personal favorite. Additionally, you could use [Tunnelblick](https://code.google.com/p/tunnelblick/), which is a free and open-source client.

For other operating systems, see [OpenVPN clients page](https://openvpn.net/index.php/access-server/docs/admin-guides/182-how-to-connect-to-access-server-with-linux-clients.html) for a list.

To summarize, we will be building the below components:

- VPC
- Internet Gateway for public subnet
- Public subnet for routing instances
- Private subnet for internal resources
- Routing tables for public and private subnets
- NAT/VPN server to route outbound traffic from your instances in private network and provide your workstation secure access to network resources.
- Application servers running nginx docker containers in a private subnet
- Load balancers in the public subnet to manage and route web traffic to app servers

Although, the above mentioned components can be built and managed using the native AWS web console, building it in such way leaves your infrastructure vulnerable to operationally changes and surprises.

Automating the building, changing, and versioning of your infrastructure safely and efficiently increases your operational readiness, exponentially. This allows you move at a higher velocity as you grow and evolve your infrastructure.

Infrastructure as code lays the foundation for agility that aligns with your agile product develop efforts and opens a pathway to easily scale to many types of clouds and manage heterogeneous information systems.

The Terraform Way
-----------------

[Terraform](https://www.terraform.io) is an automation tool for the cloud, from [Hashicorp](https://hashicorp.com) (Creators of [Vagrant](https://www.vagrantup.com), [Consul](https://www.consul.io) and many more automation favorites).

It provides powerful primitives to elegantly define your infrastructure as code. Its simple yet powerful syntax to describe infrastructure components allows you to build complex, version controlled, collaborative, heterogeneous and disposable systems with a very high productivity.

In simple terms, “terraforming” begins with you describing the desired state of your infrastructure in a configuration file. You then generate an execution ‘plan’ which describes various resources that will be created, modified and destroyed to reach the desired state.  

You can then choose to ‘apply’ this plan, which will create actual resources.

Preparing your Workstation
--------------------------

You can install terraform using [Homebrew](http://brew.sh) on a Mac using ```brew update && brew install terraform```. 

Alternatively, find the [appropriate package](https://www.terraform.io/downloads.html) for your system and download it. Terraform is packaged as a zip archive. After downloading Terraform, unzip the contents of the zip archive to a directory that is in your `PATH`, ideally under `/usr/local/bin`. You can verify that Terraform is properly installed by running `terraform`. It should return something like:

```sh
usage: terraform [--version] [--help] <command> [<args>]

Available commands are:
    apply      Builds or changes infrastructure
    destroy    Destroy Terraform-managed infrastructure
    get        Download and install modules for the configuration
    graph      Create a visual graph of Terraform resources
    init       Initializes Terraform configuration from a module
    output     Read an output from a state file
    plan       Generate and show an execution plan
    pull       Refreshes the local state copy from the remote server
    push       Uploads the the local state to the remote server
    refresh    Update local state file against real resources
    remote     Configures remote state management
    show       Inspect Terraform state or plan
    version    Prints the Terraform version
```

The Project Directory
---------------------

Create a directory to host your project files. For our example, we will use `$HOME/terraform`, with the below structure:

```sh
.
├── cloud-config
├── bin
└── ssh
```

```sh
$ mkdir -p $HOME/terraform
$ cd $HOME/terraform
$ mkdir -p cloud-config ssh bin
```

Variables for your Infrastructure
---------------------------------

Configurations can be defined in any file with a `.tf` extension using terraform syntax or as json files. It is a general practice to start with a `variables.tf` file that defines all of the variables that can be easily changed to tune your infrastructure.

Create a file called `variables.tf` with the below contents:

```
variable "access_key" { 
  description = "AWS access key"
}

variable "secret_key" { 
  description = "AWS secret access key"
}

variable "region"     { 
  description = "AWS region to host your network"
  default     = "us-west-1" 
}

variable "vpc_cidr" {
  description = "CIDR for VPC"
  default     = "10.128.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR for public subnet"
  default     = "10.128.0.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR for private subnet"
  default     = "10.128.1.0/24"
}

/* Ubuntu 14.04 amis by region */
variable "amis" {
  description = "Base AMI to launch the instances with"
  default = {
    us-west-1 = "ami-049d8641" 
    us-east-1 = "ami-a6b8e7ce"
  }
}
```

The `variable` block defines a single input variable that your configuration will require to provision your infrastructure. The `description` parameter is used to describe what the variable is  for and the `default` parameter gives it a default value. Our example requires that you provide ```access_key``` and ```secret_key``` variables and optionally provide ```region```, region will otherwise default to `us-west-1` when not provided.

Variables can also have multiple default values with keys to access them; such variables are called “maps”. Values in maps can be accessed using interpolation syntax which will be covered in upcoming sections of this guide.

The first terraform resource: VPC
---------------------------------

Create a `aws-vpc.tf` file under the current directory with the below configuration:

```
/* Setup our aws provider */
provider "aws" {
  access_key  = "${var.access_key}"
  secret_key  = "${var.secret_key}"
  region      = "${var.region}"
}

/* Define our vpc */
resource "aws_vpc" "default" {
  cidr_block = "${var.vpc_cidr}"
  enable_dns_hostnames = true
  tags { 
    Name = "airpair-example" 
  }
}
```

The `provider` block defines the configuration for the cloud providers, which is `aws` in our case. Terraform has support for various other providers like Google Compute Cloud, DigitalOcean, and Heroku. You can see a full list of supported providers on the [Terraform providers page](https://www.terraform.io/docs/providers/index.html).

The `resource` block defines the resource being created. The above example creates a VPC with a CIDR block of `10.128.0.0/16` and attaches a `Name` tag `airpair-example`. You can read more about various other parameters that can be defined for ```aws_vpc``` on the [aws_vpc resource documentation page](https://www.terraform.io/docs/providers/aws/r/vpc.html).

Parameters accept string values that can be [interpolated](https://www.terraform.io/docs/configuration/interpolation.html) when wrapped with `${}`. In the ```aws``` provider block specifying ```${var.access_key}``` for access key will read the value from the user provided for variable ```access_key```. 

You will see extensive usage of interpolation in the coming sections of this guide.

Running `terraform apply` will create the VPC by prompting you to to input AWS access and secret keys. For default values, hitting `<return>` will assign default values, defined in the `variables.tf` file. 

The output should look something like this:

```sh
$ terraform apply
var.access_key
  AWS access key

  Enter a value: foo

...

var.secret_key
  AWS secret access key

  Enter a value: bar

...

aws_vpc.default: Creating...
  cidr_block:                "" => "10.128.0.0/16"
  default_network_acl_id:    "" => "<computed>"
  default_security_group_id: "" => "<computed>"
  enable_dns_hostnames:      "" => "1"
  enable_dns_support:        "" => "0"
  main_route_table_id:       "" => "<computed>"
  tags.#:                    "" => "1"
  tags.Name:                 "" => "airpair-example"
aws_vpc.default: Creation complete

Apply complete! Resources: 1 added, 0 changed, 0 destroyed.

The state of your infrastructure has been saved to the path
below. This state is required to modify and destroy your
infrastructure, so keep it safe. To inspect the complete state
use the `terraform show` command.

State path: terraform.tfstate
```

The above command will save the state of your infrastructure to the `terraform.tfstate` file. This file will be updated each time you run `terraform apply`. You can inspect the current state of your infrastructure by running `terraform show`.

You can verify the VPC has been created by visiting the [VPC page on AWS console](https://console.aws.amazon.com/vpc/home?region=us-west-1#vpcs). 

Variables can also be entered using command arguments by specifying `-var 'var=VALUE’`. For example: ```terraform plan -var 'access_key=foo' -var 'secret_key=bar'```.

However, `terraform apply` will not save your input values (access and secret keys). You'll be required to provide them for each update. To avoid inputting values for each update, create a `terraform.tfvars` variables file with your access and secret keys that looks like the below (replace foo and bar with your values):

```
access_key = "foo"
secret_key = "bar"
```

It is a best practice not to upload this file to your source control system. For git users, make sure to include `terraform.tfvars` in the `.gitignore` file.

Adding the Public Subnet
------------------------

Let us now add a public subnet with the IP range `10.128.0.0/24` and attach an Internet Gateway. Create a `public-subnet.tf` file with the below configuration:

```
/* Internet gateway for the public subnet */
resource "aws_internet_gateway" "default" {
  vpc_id = "${aws_vpc.default.id}"
}

/* Public subnet */
resource "aws_subnet" "public" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "${var.public_subnet_cidr}"
  availability_zone = "us-west-1a"
  map_public_ip_on_launch = true
  depends_on = ["aws_internet_gateway.default"]
  tags { 
    Name = "public" 
  }
}

/* Routing table for public subnet */
resource "aws_route_table" "public" {
  vpc_id = "${aws_vpc.default.id}"
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = "${aws_internet_gateway.default.id}"
  }
}

/* Associate the routing table to public subnet */
resource "aws_route_table_association" "public" {
  subnet_id = "${aws_subnet.public.id}"
  route_table_id = "${aws_route_table.public.id}"
}
```

Anything under ```/* .. */``` will be considered as comments.

Running `terraform plan` will generate an execution plan for you to verify before creating the actual resources. It is recommended that you always inspect the plan before running the `apply` command.

Resource dependencies are implicitly determined during the refresh phase (in planing and application phases). They can also be explicitly defined using the ```depends_on``` parameter. In the above configuration, the resource ```aws_subnet.public``` depends on ```aws_internet_gatway.default``` and will only be created after ```aws_internet_gateway.default``` is successfully created. 

The output of `terraform plan` should look something like this:

```sh
$ terraform plan

Refreshing Terraform state prior to plan...

aws_vpc.default: Refreshing state... (ID: vpc-30965455)

The Terraform execution plan has been generated and is shown below.
Resources are shown in alphabetical order for quick scanning. Green resources
will be created (or destroyed and then created if an existing resource
exists), yellow resources are being changed in-place, and red resources
will be destroyed.

Note: You didn't specify an "-out" parameter to save this plan, so when
"apply" is called, Terraform can't guarantee this is what will execute.

+ aws_internet_gateway.default
    vpc_id: "" => "vpc-30965455"

+ aws_route_table.public
    route.#:                       "" => "1"
    route.~1235774185.cidr_block:  "" => "0.0.0.0/0"
    route.~1235774185.gateway_id:  "" => "${aws_internet_gateway.default.id}"
    route.~1235774185.instance_id: "" => ""
    vpc_id:                        "" => "vpc-30965455"

+ aws_route_table_association.public
    route_table_id: "" => "${aws_route_table.public.id}"
    subnet_id:      "" => "${aws_subnet.public.id}"

+ aws_subnet.public
    availability_zone:       "" => "us-west-1a"
    cidr_block:              "" => "10.128.0.0/24"
    map_public_ip_on_launch: "" => "1"
    tags.#:                  "" => "1"
    tags.Name:               "" => "public"
    vpc_id:                  "" => "vpc-30965455"
```

*The vpc_id will be different in your actual output, as compared to the example above*.

The `+` before `aws_internet_gateway.default` indicates that a new resource will be created. 

After reviewing your plan, run `terraform apply` to create your resources. You can verify that the subnet has been created by running `terraform show` or by visiting the AWS console.  

Creating Security Groups
------------------------

We will be creating 3 security groups:

- `default`: default security group that allow inbound and outbound traffic from all instances in the VPC
- `nat`: security group for NAT instances that allow SSH traffic from the internet
- `web`: security group that allows web traffic from the internet

Create your security groups in a `security-groups.tf` file with the below configuration:

```
/* Default security group */
resource "aws_security_group" "default" {
  name = "default-airpair-example"
  description = "Default security group that allows inbound and outbound traffic from all instances in the VPC"
  vpc_id = "${aws_vpc.default.id}"
  
  ingress {
    from_port   = "0"
    to_port     = "0"
    protocol    = "-1"
    self        = true
  }
  
  egress {
    from_port   = "0"
    to_port     = "0"
    protocol    = "-1"
    self        = true
  }
  
  tags { 
    Name = "airpair-example-default-vpc" 
  }
}

/* Security group for the nat server */
resource "aws_security_group" "nat" {
  name = "nat-airpair-example"
  description = "Security group for nat instances that allows SSH and VPN traffic from internet. Also allows outbound HTTP[S]"
  vpc_id = "${aws_vpc.default.id}"
  
  ingress {
    from_port = 22
    to_port   = 22
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port = 1194
    to_port   = 1194
    protocol  = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }


  tags { 
    Name = "nat-airpair-example" 
  }
}

/* Security group for the web */
resource "aws_security_group" "web" {
  name = "web-airpair-example"
  description = "Security group for web that allows web traffic from internet"
  vpc_id = "${aws_vpc.default.id}"
  
  ingress {
    from_port = 80
    to_port   = 80
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  ingress {
    from_port = 443
    to_port   = 443
    protocol  = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  
  tags { 
    Name = "web-airpair-example" 
  }
}
```

Run `terraform plan` to review your changes and then run `terraform apply`. You should see an output like this:

```sh
...

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

...
```

Create SSH Key Pair
-------------------

We will need an SSH key to be bootstrapped on the newly created instances to be able to login. Make sure you have the `ssh` directory and generate a new key by running:

```sh
$ ssh-keygen -t rsa -C "insecure-deployer" -P '' -f ssh/insecure-deployer
```

The above command will create a public-private key pair in the `ssh` directory. This is an insecure key and should be replaced after the instance is bootstrapped.

Create a new file `key-pairs.tf` with the below configuration and register the newly generated SSH key pair by running`terraform plan` and `terraform apply`.

```
resource "aws_key_pair" "deployer" {
  key_name = "deployer-key"
  public_key = "${file(\"ssh/insecure-deployer.pub\")}"
}
```

Terraform interpolation syntax also allows reading data from files using `$file("path/to/file")`. Variables in this file are not interpolated. The contents of the file are read as-is.

Create the NAT Instance
-----------------------

NAT instances reside in the public subnet. In order to route traffic, they need to have the ’source destination check' parameter disabled. They belong to the `default` and `nat` security groups. The `default` security group allows traffic from any instance within the group. The `nat` security group allows SSH and VPN traffic from the internet. 

Create a file `nat-server.tf` with the below configuration:

```
/* NAT/VPN server */
resource "aws_instance" "nat" {
  ami = "${lookup(var.amis, var.region)}"
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.public.id}"
  security_groups = ["${aws_security_group.default.id}", "${aws_security_group.nat.id}"]
  key_name = "${aws_key_pair.deployer.key_name}"
  source_dest_check = false
  tags = { 
    Name = "nat"
  }
  connection {
    user = "ubuntu"
    key_file = "ssh/insecure-deployer"
  }
  provisioner "remote-exec" {
    inline = [
      "sudo iptables -t nat -A POSTROUTING -j MASQUERADE",
      "echo 1 | sudo tee /proc/sys/net/ipv4/conf/all/forwarding > /dev/null",
      /* Install docker */ 
      "curl -sSL https://get.docker.com/ubuntu/ | sudo sh",
      /* Initialize open vpn data container */
      "sudo mkdir -p /etc/openvpn",
      "sudo docker run --name ovpn-data -v /etc/openvpn busybox",
      /* Generate OpenVPN server config */
      "sudo docker run --volumes-from ovpn-data --rm gosuri/openvpn ovpn_genconfig -p ${var.vpc_cidr} -u udp://${aws_instance.nat.public_ip}"
    ]
  }
}
```

In order for the NAT instance to route traffic, [iptables](http://ipset.netfilter.org/iptables.man.html) needs to be configured with a rule in the `nat` table for [IP Masquerade](http://www.tldp.org/HOWTO/IP-Masquerade-HOWTO/ipmasq-background2.1.html). We also need to install Docker, download the OpenVPN container and generate server configuration.

Terraform provides a set of [provisioning options](https://www.terraform.io/docs/provisioners/index.html) that can be used to run arbitrary commands on instances, immediately after they are created.

The `connection` block defines the [connection parameters](https://www.terraform.io/docs/provisioners/connection.html) for SSH access to the instance.

Create Private Subnet and Routes
--------------------------------

Create a Private Subnet with the CIDR range `10.128.1.0/24` and configure the routing table to route all traffic via the NAT. Create a `private-subnets.tf` file with the below configuration:

```
/* Private subnet */
resource "aws_subnet" "private" {
  vpc_id            = "${aws_vpc.default.id}"
  cidr_block        = "${var.private_subnet_cidr}"
  availability_zone = "us-west-1a"
  map_public_ip_on_launch = false
  depends_on = ["aws_instance.nat"]
  tags { 
    Name = "private" 
  }
}

/* Routing table for private subnet */
resource "aws_route_table" "private" {
  vpc_id = "${aws_vpc.default.id}"
  route {
    cidr_block = "0.0.0.0/0"
    instance_id = "${aws_instance.nat.id}"
  }
}

/* Associate the routing table to public subnet */
resource "aws_route_table_association" "private" {
  subnet_id = "${aws_subnet.private.id}"
  route_table_id = "${aws_route_table.private.id}"
}
```

Notice our second time use of ```depends_on```. In the above case, ```depends_on``` only creates the private subnet after the NAT instance is created and successfully provisioned. Without the `iptables` configuration, the instances in the private subnet will not be able to access the internet and will fail to download Docker containers.

Run ```terraform plan``` and ```terraform apply``` to create the resources.

Adding Application Servers with a Load Balancer
-----------------------------------------------

Let us add two app servers running nginx containers in the private subnet and configure a load balancer in the public subnet. 

The app servers are not accessible directly from the internet and can be accessed via the VPN. Since we haven't configured our VPN yet to access the instances, we will provision the instances by bootstrapping a `cloud-init` configuration file via the ```user_data``` resource parameter.

The defacto multi-distribution package [cloud-init](http://cloudinit.readthedocs.org/en/latest/topics/examples.html) handles early initialization of a cloud instance.

Create the `app.yml` cloud config file under `cloud-config` directory with the below configuration:

```yaml
#cloud-config
# Cloud config for application servers 

runcmd:
  # Install docker
  - curl -sSL https://get.docker.com/ubuntu/ | sudo sh
  # Run nginx
  - docker run -d -p 80:80 dockerfile/nginx

```

Create the `app-servers.tf` file with the below configuration:

```
/* App servers */
resource "aws_instance" "app" {
  count = 2
  ami = "${lookup(var.amis, var.region)}"
  instance_type = "t2.micro"
  subnet_id = "${aws_subnet.private.id}"
  security_groups = ["${aws_security_group.default.id}"]
  key_name = "${aws_key_pair.deployer.key_name}"
  source_dest_check = false
  user_data = "${file(\"cloud-config/app.yml\")}"
  tags = { 
    Name = "airpair-example-app-${count.index}"
  }
}

/* Load balancer */
resource "aws_elb" "app" {
  name = "airpair-example-elb"
  subnets = ["${aws_subnet.public.id}"]
  security_groups = ["${aws_security_group.default.id}", "${aws_security_group.web.id}"]
  listener {
    instance_port = 80
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }
  instances = ["${aws_instance.app.*.id}"]
}
```

The `count` parameter indicates the number of identical resources to create. The `${count.index}` interpolation in the name tag provides the current index.

You can read more about using count in resources at [terraform variable documentation](https://www.terraform.io/docs/configuration/resources.html#using-variables-with-count).

Run ```terraform plan``` and then ```terraform apply```.

Easily Accessing Computed Data from other Programs
--------------------------------------------------

Terraform allows persisting computed values in output variables. The output variables defined in the configuration can be accessed by running ```terraform output VARIABLE```, from the shell.

Create the `outputs.tf` file with the below configuration:

```
output "app.0.ip" {
  value = "${aws_instance.app.0.private_ip}"
}

output "app.1.ip" {
  value = "${aws_instance.app.1.private_ip}"
}

output "nat.ip" {
  value = "${aws_instance.nat.public_ip}"
}

output "elb.hostname" {
  value = "${aws_elb.app.dns_name}"
}
```

Since we are not changing any values this time, running `terraform apply` will populate outputs in the state file. Inspect the `elb.hostname` by running:

```sh
$ open "http://$(terraform output elb.hostname)"
```

The above command will open a web browser with the Load balancer’s address. If you get a connection error, it is likely that the DNS has not propagated in time and you should try again after a few minutes.

Configure OpenVPN Server and Generate Client Configuration
----------------------------------------------------------

The below steps configure the VPN server and generate a client configuration to connect with the OpenVPN client from your workstation. The keys will be embedded in the generated client OpenVPN configuration file.

Considering the commands are fairly long, we will be creating command wrappers to be able to easily run them again. A big part of improving operationally efficiency comes from our ability to simplify complicated commands. We will save the commands in the `bin` directory as executable files.

1. Initialize PKI and save the command the under bin/ovpn-init

  ```sh
  $ cat > bin/ovpn-init <<EOF
  ssh -t -i ssh/insecure-deployer \
  "ubuntu@\$(terraform output nat.ip)" \
  sudo docker run --volumes-from ovpn-data --rm -it gosuri/openvpn ovpn_initpki
  EOF

  $ chmod +x bin/ovpn-init 
  $ bin/ovpn-init
  ```
  
The above command will prompt you for a passphrase for the root certificate. Choose a strong passphrase and store it some where safe. This passphrase is required every time you generate a new client configuration.

2. Start the VPN server

  ```sh
  $ cat > bin/ovpn-start <<EOF
  ssh -t -i ssh/insecure-deployer \
  "ubuntu@\$(terraform output nat.ip)" \
  sudo docker run --volumes-from ovpn-data -d -p 1194:1194/udp --cap-add=NET_ADMIN gosuri/openvpn
  EOF
  
  $ chmod +x bin/ovpn-start
  $ bin/ovpn-start
  ```

3. Generate client certificate

  ```sh
  $ cat > bin/ovpn-new-client <<EOF
  ssh -t -i ssh/insecure-deployer \
  "ubuntu@\$(terraform output nat.ip)" \
  sudo docker run --volumes-from ovpn-data --rm -it gosuri/openvpn easyrsa build-client-full "\${1}" nopass
  EOF

  $ chmod +x bin/ovpn-new-client
  # generate a configuration for your user
  $ bin/ovpn-new-client $USER
  ```

4. Download OpenVPN client configuration

  ```sh
  $ cat > bin/ovpn-client-config <<EOF
  ssh -t -i ssh/insecure-deployer \
  "ubuntu@\$(terraform output nat.ip)" \
  sudo docker run --volumes-from ovpn-data --rm gosuri/openvpn ovpn_getclient "\${1}" > "\${1}-airpair-example.ovpn"
  EOF

  $ chmod +x bin/ovpn-client-config
  $ bin/ovpn-client-config $USER
  ```

5. The above command creates a `$USER-airpair-example.ovpn` client configuration file in the current directory. Double-click on the file to import the configuration to your VPN client. You can also connect using an iPhone/Android device. Check out [OpenVPN Connect for iPhone](https://itunes.apple.com/us/app/openvpn-connect/id590379981?mt=8) and [OpenVPN Connect on Play Store](https://play.google.com/store/apps/details?id=net.openvpn.openvpn&hl=en).

Test your Private Connection
----------------------------

After successfully connecting using the VPN client, connect to one of the app servers using a private IP address.

Run the below command to open a web browser with the instance’s private IP address. You have valid connection if you see the default nginx page.

```sh
$ open "http://$(terraform output app.1.ip)"

```

Alternatively, you can also SSH into the private instance:

```sh
$ ssh -t -i ssh/insecure-deployer "ubuntu@$(terraform output app.1.ip)"
```

Teardown infrastructure
-----------------------

Destroy the infrastructure you just created by running `destroy` command and answering with `yes` for confirmation. Make sure to first disconnect from the VPN to retain internet connection:

```sh
$ terraform destroy

Do you really want to destroy?
  Terraform will delete all your managed infrastructure.
  There is no undo. Only 'yes' will be accepted to confirm.

  Enter a value: yes

...

Apply complete! Resources: 0 added, 0 changed, 16 destroyed.
```

Conclusion
----------

There is a lot more to Terraform than what is covered in this guide. Checkout [terraform.io](https://terraform.io) and the [Github project](http://github.com/hashicorp/terraform) to see more of this awesome tool.

I hope you found this guide useful. I gave my best to keep the it accurate and updated. If there is any part of the guide that you felt could use improvement, make your updates in a [fork](https://www.airpair.com/posts/fork/54f3d0b292e9370c00ae049f) and send me a pull request. I will attend to it promptly. 

I'm hoping to continue to write more guides on various topics that I think will be useful. If you have a recommendation for topic or simply want to stay connected, I'm on twitter [@kn0tch](https://twitter.com/kn0tch). I'm usually active and always looking forward to a good conversation; come say hi!
