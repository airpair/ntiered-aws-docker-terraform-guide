Data is a crucial part of our infrastructure and particularly vulnerable while it is traveling over the Internet. Securing its transportation is a fundamental requirement for a secure network. 

While there are serval transport level protocols available for encrypting the transit, communicating privately in a closed network is the most common and efficient way to keep data secure.

I wrote this guide in an attempt to help the reader build such a network on AWS along with a secure way to access it’s resources using a VPN.

Before we begin
---------------

This is a technical guide and the reader is expected to have a basic linux command line knowledge. The audience this guide is intended for:
 
- Application developers with little or no systems administration experience and wanting to deploy applications on AWS.
- System administrators with little or no experience with infrastructure automation and wanting to learn more.
- Infrastructure automation engineers that want to explore cloud provider resource automation.
- Any one that wants to get a feel for the current state of cloud automation tooling.

I kept the scope limited to building a private network and did not cover application and OS level security which are also equally important.

As you walk thru various sections of this guide, you will be creating real aws resources that cost money. I did my best to keep the utilization footprint to the lowest possible configuration and I estimate less than hour to complete all the steps in this guide at $0.079/hr

By the end, to demonstrate the disposable nature of infstrasture-as-code, we will be destroying all the infrastructure components that were created during the course of this tutorial.

Please have the below ready before we begin:

- AWS access and secret keys to an active AWS account.
- A unix/linux workstation with internet connection, almost all commands will work on Windows too with a shell emulator like cygwin.

The Private Network
-------------------

During the course of this tutorial, we will essentially be building a Virtual Private Cloud (VPC) on AWS along with a public and a private subnet (sub-networks) pair. 

Instances in the private subnet cannot directly access the internet thereby making the subnet an ideal place for application and database servers. 

We will also be building two application instances that reside in the private subnet. The private subnet will also be where you should be hosting application support instances like database instances, cache servers, log hosts, build servers, configuration stores etc. Instances in the private subnet rely on a Network Address Translation (NAT) server running in the public subnet to connect to the internet. 

All Instances in the public subnet can transmit inbound and outbound traffic to and from the internet, the routing resources such as load balancers, vpn and nat servers reside in this subnet. 

The NAT server we will be building will also run an OpenVPN server. Its a full-featured SSL VPN which implements OSI layer 3 secure network extension using the industry standard SSL/TLS protocol over a UDP encapsulated network.

In the later part of this guide, we will connect to our private network using via this VPN server using a compatible OpenVPN client. On a Mac, [Viscosity](https://www.sparklabs.com/viscosity) is a good commercial client and my personal favorite. [Tunnelblick](https://code.google.com/p/tunnelblick/) is free and open-source client that’s compatible too. 

For other operating systems, see [openvpn clients page](https://openvpn.net/index.php/access-server/docs/admin-guides/182-how-to-connect-to-access-server-with-linux-clients.html) for a list.

To summarize, we will be building the below components:

- VPC
- Internet Gateway for public subnet
- Public subnet for routing instances
- Private subnet for application resources
- Routing tables for public and private subnets
- NAT/VPN server to route outbound traffic from your instances in private network and provide your workstation secure access to network resources.
- Application servers running nginx docker containers in a private subnet
- Load balancers in the public subnet to manage and route web traffic to app servers

Although all the above mentioned components can be built and managed using the native AWS web console, building it such way leaves your infrastructure vulnerable to operationally changes and surprises. 

Automating the building, changing, and versioning your infrastructure safely and efficiently increases your operational readiness exponentially. It allows you move at an higher velocity as you grow and evolve your infrastructure. 

Infrastructure as code lays the foundation for agility that aligns with your product develop efforts opens a path way to easily scale to many types of clouds to manage heterogeneous information systems.

The Terraform Way
-----------------

[Terraform](https://www.terraform.io) is an automation tool for the cloud from [Hashicorp](https://hashicorp.com) (Creators of [Vagrant](https://www.vagrantup.com), [Consul](https://www.consul.io) and many more sysadmin favorites).

It provides powerful primitives to elegantly define your infrastructure as code. It’s simple yet powerful syntax to describe infrastructure components allow you to build complex, version controlled, collaborative, heterogeneous and disposable systems at a very high productivity.

In simple terms, terraforming begins with you describing the desired state of your infrastructure in a configuration file, it then generates an execution plan describing what it will do to reach that desired state. You can then choose to execute (or modify) the plan to build, remove or modify desired components.

Preparing your workstation
--------------------------

You can install terraform using [Homebrew](http://brew.sh) on a Mac using ```brew update && brew install terraform```. 

Alternative, find the [appropriate package](https://www.terraform.io/downloads.html) for your system and download it. Terraform is packaged as a zip archive. After downloading Terraform, unzip the contents of the zip archive to directory that is in your `PATH`, ideally under `/usr/local/bin`. You can verify terraform is properly installed by running `terraform`, it should return something like:

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

Your project directory
----------------------

Create a directory to host your project files. For our example, we will use `$HOME/infrastructure`, with the below structure:

```sh
.
├── cloud-config
├── bin
└── ssh
```

```sh
$ mkdir -p $HOME/infrastructure
$ cd $HOME/infrastructure
$ mkdir -p cloud-config ssh bin
```

Defining variables for your infrastructure
------------------------------------------

Configurations can be defined in any file with '.tf' extension using terraform syntax or as json files. Its a general practice to start with a `variables.tf` that defines all variables that can be easily changed to tune your infrastructure.
Create a file called `variables.tf` with the below contents:

```
variable "access_key" { 
  description = "AWS access key"
}

variable "secret_key" { 
  description = "AWS secert access key"
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

The `variable` block defines a single input variable your configuration will require to provision your infrastructure, `description` parameter is used to describe what the variable is  for and the `default` parameter gives it a default value, our example requires that you provide ```access_key``` and ```secret_key``` variables and optionally provide ```region```, region will otherwise default to `us-west-1` when not provided.

Variables can also have multiple default values with keys to access them, such variables are called maps. Values in maps can be accessed using interpolation syntax which will be covered in the coming sections of the guide.

Creating your first terraform resource - VPC
---------------------------------------------

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

The `provider` block defines the configuration for the cloud providers, aws in our case. Terraform has support for various other providers like Google Compute Cloud, DigitalOcean, Heroku etc. You can see a full list of supported providers on the [terraform providers page](https://www.terraform.io/docs/providers/index.html).

The `resource` block defines the resource being created. The above example creates a VPC with a CIDR block of `10.128.0.0/16` and attaches a `Name` tag `airpair-example`, you can read more about various other parameters that can be defined for ```aws_vpc``` on the [aws_vpc resource documentation page](https://www.terraform.io/docs/providers/aws/r/vpc.html)

Parameters accepts string values that can be [interpolated](https://www.terraform.io/docs/configuration/interpolation.html) when wrapped with `${}`. In the ```aws``` provider block, specifying ```${var.access_key}``` for 
for access key will read the value from the user provided for variable ```access_key```. 

You will see extensive usage of interpolation in the coming sections of this guide.

Running `terraform apply` will create the VPC by prompting you to to input AWS access and secret keys, the output should look like look like the below. For default values, hitting `<return>` key will assign default values defined in the `variables.tf` file.

```sh
$ terraform apply
var.access_key
  AWS access key

  Enter a value: foo

...

var.secret_key
  AWS secert access key

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

You can verify the VPC has been created by visiting the [VPC page on aws console](https://console.aws.amazon.com/vpc/home?region=us-west-1#vpcs). The above command will save the state of your infrastructure to `terraform.tfstate` file, this file will be updated each time you run `terraform apply`, you can inspect the current state of your infrastructure by running `terraform show`

Variables can also be entered using command arguments by specifying `-var 'var=VALUE'`, for example ```terraform plan -var 'access_key=foo' -var 'secret_key=bar'```

`terraform apply` will not however save your input values (access and secret keys) and you'll be required to provide them for each update, to avoid this create a `terraform.tfvars` variables file with your access and secret keys that looks like, the below (replace foo and bar with your values):

```
access_key = "foo"
secret_key = "bar"
```

Adding the public subnet
------------------------

Lets now add a public subnet with a ip range of 10.128.0.0/24 and attach a internet gateway, create a `public-subnet.tf` with the below configuration:

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

Running `terraform plan` will generate an execution plan for you to verify before creating the actual resources, it is recommended that you always inspect the plan before running the `apply` command.

Resource dependencies are implicitly determined during the refresh phase (in planing and application phases). They can also be explicitly defined using ```depends_on``` parameter. In the above configuration, resource ```aws_subnet.public``` depends on ```aws_internet_gatway.default``` and will only be created after ```aws_internet_gateway.default``` is successfully created. 

The output of `terraform plan` should look something like the below:

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

*The vpc_id will different in your actual output from the above example output*

The `+` before `aws_internet_gateway.default` indicates that a new resource will be created. 

After reviewing your plan, run `terraform apply` to create your resources. You can verify the subnet has been created by running `terraform show` or by visiting the aws console.  

Creating security groups
------------------------

We will creating 3 security groups:

- default: default security group that allows inbound and outbound traffic from all instances in the VPC
- nat: security group for nat instances that allows SSH traffic from internet
- web: security group that allows web traffic from the internet

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
  
  tags { 
    Name = "airpair-example-default-vpc" 
  }
}

/* Security group for the nat server */
resource "aws_security_group" "nat" {
  name = "nat-airpair-example"
  description = "Security group for nat instances that allows SSH and VPN traffic from internet"
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

Run `terraform plan`, review your changes and run `terraform apply`. You should see a message:

```sh
...

Apply complete! Resources: 3 added, 0 changed, 0 destroyed.

...
```

Create SSH Key Pair
-------------------

We will need a default ssh key to be bootstrapped on the newly created instances to be able to login. Make sure you have `ssh` directory and generate a new key by running the:

```sh
$ sh-keygen -t rsa -C "insecure-deployer" -P '' -f ssh/insecure-deployer
```

The above command will create a public-private key pair in `ssh` directory, this is an insecure key and should be replaced after the instance is bootstrapped.

Create a new file `key-pairs.sh` with the below config and register the newly generated SSH key pair by running`terraform plan` and `terraform apply`.

```
resource "aws_key_pair" "deployer" {
  key_name = "deployer-key"
  public_key = "${file(\"ssh/insecure-deployer.pub\")}"
}
```

Terraform interpolation syntax also allows reading data from files using `$file("path/to/file")`. Variables in this file are not interpolated. The contents of the file are read as-is.

Create NAT Instance
-------------------

NAT instances reside in the public subnet and in order to route traffic, they need to have 'source destination check' disabled. They belong to the `default` secruity group to allow traffic from instances in that group and `nat` security group to allow SSH and VPN traffic from the internet. 

Create a file `nat-server.tf` with the below config:

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
      "echo 1 > /proc/sys/net/ipv4/conf/all/forwarding",
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

In order for that NAT instance to route packets, [iptables](http://ipset.netfilter.org/iptables.man.html) needs to be configured be with a rule in the `nat` table for [IP Masquerade](http://www.tldp.org/HOWTO/IP-Masquerade-HOWTO/ipmasq-background2.1.html). We also need to install docker, download the openvpn container and generate server configuration.

Terraform provides a set of [provisioning options](https://www.terraform.io/docs/provisioners/index.html) that can be used to run arbitrary commands on the instances when they are created. For our nat instance above, we use ```remote-exec``` to execute the set of commands on the instance.

``connection`` block defines the [connection parameters](https://www.terraform.io/docs/provisioners/connection.html) for ssh access to the instance.

Create private subnet and configure routing
-------------------------------------------

Create a private subnet with a CIDR range of 10.128.1.0/24 and configure the routing table to route all traffic via the nat. Append 'main.tf' with the below config:

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

Notice our second time use of ```depends_on```, in this case it only creates the private subnet after provisioning the NAT instance. With out the iptables configuration, the instances in the private subnet will not be able to access internet and will fail to download docker containers.

Run ```terraform plan``` and ```terraform apply``` to create the resources.

Adding app instances and a load balancer
----------------------------------------

Lets add two app servers running nginx containers in the private subnet and configure a load balancer in the public subnet. 

The app servers are not accessible directly from the internet and can be accessed via the VPN. Since we haven't configured our VPN yet to access the instances, we will provision the instances using by bootrapping `cloud-init` yaml file via the ```user_data``` parameter.

`cloud-init` is a defacto multi-distribution package that handles early initialization of a cloud instance. You can see various examples [in the documentation](http://cloudinit.readthedocs.org/en/latest/topics/examples.html)

Create `app.yml` cloud config file under `cloud-config` directory with the below config:

```yaml
#cloud-config
# Cloud config for application servers 

runcmd:
  # Install docker
  - curl -sSL https://get.docker.com/ubuntu/ | sudo sh
  # Run nginx
  - docker run -d -p 80:80 dockerfile/nginx

```

Create `app-servers.tf` file with the below configuration:

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

`count` parameter indicates the number of identical resources to create and `${count.index}` interpolation in the name tag provides the current index.

You read more about using count in resources at [terraform variable documentation](https://www.terraform.io/docs/configuration/resources.html#using-variables-with-count)

Run ```terraform plan``` and ```terraform apply```

Allowing generated configuration to be easily accessable to other programs
--------------------------------------------------------------------------

Terraform allows for defining output to templates, output variables can be accessed by running ```terraform output VARIABLE```.

Create `outputs.tf` file with the below configuration:

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

Since we are not changing any values, run `terraform apply` to populate outputs in the state file. Inspect the `elb.hostname` by running:

```sh
$ open "http://$(terraform output elb.hostname)"
```

The above command will open a web browser. If you get an connection error, it is likely the DNS has not propogated in time and you should try again after a few minutes.

Configure OpenVPN server and generate client config
---------------------------------------------------

The below steps configure the VPN servers and generate a client configuration with embedded keys to connect with your openvpn client on your workstation. 

Considering the commands are fairly long, we will be creating command wrappers to be able to easily run them again. A big part of operatinaly effiency comes from our ability to simply complicated commands which are unlikely to be easily recalled. After each successful step, we will save the command under `bin` in an executable file. 

1. Initialize PKI and save the command under bin/ovpn-init

  ```sh
  $ cat > bin/ovpn-init <<EOF
  ssh -t -i ssh/insecure-deployer \
  "ubuntu@\$(terraform output nat.ip)" \
  sudo docker run --volumes-from ovpn-data --rm -it gosuri/openvpn ovpn_initpki
  EOF

  $ chmod +x bin/ovpn-init 
  $ bin/ovpn-init
  ```
  
  The above command will prompt you for a passphrase for the root certificate, choose a strong passphrase and store it in a safe place. This passphrase is required every time you genenerate a new client configuration.

2. Start the VPN server.

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

4. Download VPN config

  ```sh
  $ cat > bin/ovpn-client-config <<EOF
  ssh -t -i ssh/insecure-deployer \
  "ubuntu@\$(terraform output nat.ip)" \
  sudo docker run --volumes-from ovpn-data --rm gosuri/openvpn ovpn_getclient "\${1}" > "\${1}-airpair-example.ovpn"
  EOF

  $ chmod +x bin/ovpn-client-config
  $ bin/ovpn-client-config $USER
  ```

5. The above command creates `$USER-airpair-example.ovpn` client configuration file in the current directory, double click on the file to import the configuration to your VPN client. You can also connection using iPhone/Android device, check out [OpenVPN Connect for iPhone](https://itunes.apple.com/us/app/openvpn-connect/id590379981?mt=8) and [OpenVPN Connect on Play Store](https://play.google.com/store/apps/details?id=net.openvpn.openvpn&hl=en)

Test your private connection
----------------------------

After successfully connecting using the VPN client, connect to one of app servers using a private IP address to validate that you have a connection:

```sh
$ open "http://$(terraform output app.1.ip)"

```

Alternatively, you can also ssh into the private instance

```sh
$ ssh -t -i ssh/insecure-deployer "ubuntu@$(terraform output app.1.ip)"
```

Teardown infrastructure
-----------------------

Destroy our infructure by running `destroy` command and answering with `yes` for confimation, make sure to disconnect from the VPN to be retain internet connection:

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

There is a lot more to Terraform than what was convered in this post, checkout [terraform.io](https://terraform.io) and the [github project](http://github.com/hashicorp/terraform) to see more this amazing tool.

I hope you found this guide useful, I gave my best to keep the it accurate and updated, if there is any part of the guide that you felt could use imporovement, please leave a comment and I will attend to it promptly. 

I'm hoping to continue to write more guides on various topics that I think will be useful. If you have a recomendation for topic or want simply want stay connected, I'm on twitter [@kn0tch](https://twitter.com/kn0tch). I'm usually active and always looking foward to a good conversation, come say hi!
