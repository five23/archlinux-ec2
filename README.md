# Building Arch Linux EC2 AMIs from scratch

The official AWS documentation around building AMI's usually involves taking an
existing AMI, adding a few things, and saving the result as a new AMI. What to
do, though, if you'd rather install your [favorite Linux
distribution](https://archlinux.org) then build on any of the existing
installations[^1]?

This is a bit of code and complementary instructions to build an AMI completely
from scratch, using [packer.io](https://packer.io) and the Arch Linux
bootstrapping tools (`pacstrap` and friends).

## Prerequisites

All you need is an AWS account (with a VPC and subnet set up), some open source
tools, one working Arch Linux system, and a bit of time. I am assuming basic
knowledge of EC2, such as what an EBS volume is and what an AMI is. It probaly
also helps to understand what `chroot` does, and ideally you have at least once
before installed Arch Linux on some computer.

## A bit of theory

There are two ways to build your own AMIs. The easiest one is best summed up as
"take an existing AMI, run some commands, save the result as new AMI". This is
very simple, but lacks a bit in flexibility.

The other one is more comparable to actually installing Linux on a box. You
boot into an existing AMI (usually the installer ISO or disk image), and use
the appropriate tools (for Arch Linux, `pacstrap`) to install a new system to
an additional hard drive (usually your computer's hard drive). In case of AWS,
this means an additional EBS volume. We can then take this EBS volume and turn
it into an AMI.

The latter approach is historically less well-documented, and it is not always
entirely clear what is needed to make a system bootable - and also usable - in
EC2. I think this has mostly historic reasons, as it used to be notoriously
difficult to get a Linux image to boot but in EC2. However, this is not really
the case anymore. These instructions will help you create an almost vanilla
Arch Linux image, with all modifications commented in the code so you can get a
better understanding of what it takes to run in EC2.

Note that we have to jump through one additional hoop here to make all of this
work: we will be booting an ordinary Debian AMI for the installation, so none
of the Arch Linux tools are readily available. To work around this, we'll use a
basic Arch Linux system that we can chroot into, and use that to bootstrap the
new system.

As such, the outline of the entire process is as follows:

 - On an existing Arch Linux installation, create a tarball of a minimal Arch bootstrap system
 - Use packer to ...
   - Boot an EC2 instance with an ordinary Debian AMI and a second, empty EBS volume attached
   - Upload the Arch system tarball to the instance
   - Run a script on that host that will ...
     - Extract the above tarball
     - Chroot into the minimal Arch system to use its tools to bootstrap Arch Linux onto the second EBS volume
     - Make a few changes to the bootstrapped system to make it usable in EC2
   - Create an AMI from the second EBS volume

So let's get going!

## Content of this repo

### The Makefile

As every project should have, there is a litte Makefile that describes the
steps needed to achieve certain tasks. It is the starting point for any
customizations, some of which are mandatory (like specifying some of your AWS
setup details).

A Makefile supports comments, so I tried to describe everything in detail in
the code itself. After finishing this document, you should read (and edit, in
fact) the Makefile first.

### Packer config

Packer is a tool to build disk images for all kinds of cloud services, also
EC2. Moreover, it has a special builder called the [EBS Surrogate
builder](https://www.packer.io/docs/builders/amazon-ebssurrogate.html), which
does exactly what we need: it let's you start an EC2 instance with and existing
AMI, attach an additional EBS volume, do random stuff with that volume and then
create a new AMI from that volume.

All this is no magic, and you could easily do the same thing without packer.
However, to focus on the important parts, and for ease of automation, packer is
very valuable.

The file `packer-cfg.json` is the configuration file we use for packer. It
declares some variables at the top, so that they can be passed in on the
command line (as seen in the Makefile).

Unfortunately a JSON file can not really have comments, but the file should be
fairly self-explanatory. It also doesn't really contain anything interesting -
it's mostly administrative settings. For all the juicy stuff, read on below.

### The provisioning script

Once packer has set up our EC2 instance with the additional EBS volume, it
needs instructions what to do. Our packer config specifies that it should run
the script `provision.sh` (on the EC2 instance). This script does all the heavy
lifting.  Fortunately, a shell script can also have comments, and I made
liberal use of that. If you are curious how all this works, this script is
where to start looking.

## Build process

This section assumes that you are working with this repository on an Arch Linux
system.

The TL;DR summary is: after making the necessary changes to the Makefile
(change AWS settings and AMI name), run

    make packages
    sudo make tarball
    make ami

But I strongly recommend reading through the more detailed instructions below.

### Setting up the Makefile

Carefully read through the Makefile and change all the variables at the top to
your liking. The comments in the file should guide you, but it's mostly setting
up the specifics of your AWS environment. 

###  Build AUR packages

Even though they are - strictly speaking - optional, we will add two packages
from AUR to our final system in order to make the result more usable as a
general purpose AMI. In order to do this, we will build those packages from
source and include them in the tarball.

#### growpart

When you create an AMI, you create a disk image of a certain size, in this case
4GB. When you launch an instance with this AMI, it needs at least 4GB of
storage. However, it can easily have more. But even when you launch an instance
with 10GB storage, the disk image still contains the main partition of ~4GB.
To make the additional storage available, the partition as well as the file
system it contains needs to be resized to fill all available space. This is
what growpart does.

#### netplan

[Netplan](https://netplan.io) is a generic network configuration renderer used
by cloud-init to render a systemd-networkd configuration. Without this, you
would have to bake the network configuration into the AMI itself, which would
make it a lot less versatile.

#### Building

To build the packages, run `make packages`. Do not run this as root, as this
will execute `makepkg`, which should not be run as root. You may have to
install a bunch of dependencies, but the `makepkg` output will tell you exactly
what.

### Create the base Arch tarball

This tarball will be used on the Debian AMI to gain access to the Arch tooling.
The recipe uses `pacstrap` to create a basic system with the packages we need
plus the AUR packages we built earlier. It involves barely any actual
configuration since this "system" doesn't have to be bootable, we will just
`chroot` into it.

To create it, run `sudo make tarball` (or just `make tarball` as root). Note
that there is some mounting involved in the process, so if the build fails you
might end up with some of the mounts still in place. Running `sudo make clean`
should take care of that (it will also clean everything else, including the AUR
packages built for the previous section).

### Run packer

Now, all that's left is to run packer. If all your AWS settings are correct, it
will just take a while and you will end up with a fresh Arch Linux AMI!

## Resulting AMI

If everything was successful, you have an almost vanilla Arch Linux AMI that
should cover the most common use cases:

 * Networking hardware supported on most common instance types
 * The network is configured by cloud-init and netplan, even sophisticated
   configurations should work out of the box
 * The root file system will be resized to the size of the instances primary
   EBS volume on first launch
 * The key you select can be used to log in as user "arch" on the instance
   (make sure the network ACLs allow SSH)

There is most likely a bunch of advanced stuff that will not work out of the
box with this AMI.  But if you have read and understood the source, you should
see that getting something to run on EC2 is no magic. If you have a use case
that seems reasonably "general" but doesn't work with the AMI, feel free to
create an issue.

[^1]: Yes, I am aware that there are Arch Linux AMIs out there, but this is about
      learning how to do it, of course.

