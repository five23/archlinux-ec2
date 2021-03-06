# Makefile for building Arch Linux EC2 images with packer.io
#
# https://gitlab.com/bitfehler/archlinux-ec2

# The AWS credentials (which packer needs) are not set anywhere in this
# project. The intention is to use the "Environment variables" or "Shared
# Credentials file" approach outlined here:
# https://www.packer.io/docs/builders/amazon.html

# Either change the following variables in the Makefile, or pass them in
# through the environment, for example by creating an env file and running
# `set -a && source settings.env && set +a && make ami`.

# The AWS region/vpc/subnet in which to build the AMI. If you want the AMI to
# be build for multiple regions, please edit the packer config itself.
AWS_REGION      ?= eu-west-1
AWS_VPC         ?= vpc-1234abcd
AWS_SUBNET      ?= subnet-1234abcd

# The source AMI is the Debian AMI used to boot the builder VM. The ID depends
# on the region, see https://wiki.debian.org/Cloud/AmazonEC2Image/
SOURCE_AMI      ?= ami-02498d1ddb8cc6a86

# A name for your AMI. Constraints: 3-128 alphanumeric characters, parentheses
# (()), square brackets ([]), spaces ( ), periods (.), slashes (/), dashes (-),
# single quotes ('), at-signs (@), or underscores(_)
AMI_NAME        ?= archlinux-custom-ami

# A brief description of the AMI
AMI_DESCRIPTION ?= Arch Linux AMI built with Packer.io ebssurrogate builder

# Name tag for instance and volumes used to build the AMI
BUILDER_NAME    ?= archlinux-custom-ami-builder

# How to build the AUR packages. Could be `makepkg` or `makechrootpkg`, can
# include arguments (e.g. chroot location).
MAKEPKG         ?= makepkg

# Probably no need to change any of these
TARBALL = archbase.tar.gz
TMP     = ./target
PKGS    = ./pkgs
PKGEXT  = pkg.tar.zst

# If you add or remove packages here, also add/remove them in provision.sh
PACKAGES = $(PKGS)/growpart.$(PKGEXT)

# End of variables. Feel free to study the rest, but it "should" just work...

tarball: $(TARBALL)

packages: $(PACKAGES)

$(PKGS)/%.$(PKGEXT):
	mkdir -p "$(PKGS)"
	cd "$(PKGS)" && ( test -d "$*" || git clone https://aur.archlinux.org/$*.git )
	rm -f "$(PKGS)/$*/$*-*.$(PKGEXT)"
	cd "$(PKGS)/$*" && git pull
	cd "$(PKGS)/$*" && $(MAKEPKG)
	cp "$(PKGS)/$*/$*-"*".$(PKGEXT)" "$@"

$(TARBALL): $(PACKAGES)
	pacstrap -c $(TMP) base base-devel arch-install-scripts sudo 
	echo "en_US.UTF-8 UTF-8" >> $(TMP)/etc/locale.gen
	echo "LANG=en_US.UTF-8" >> $(TMP)/etc/locale.conf
	arch-chroot $(TMP) locale-gen
	mount --bind $(TMP) $(TMP)
	cp $(PKGS)/*.$(PKGEXT) $(TMP)/
	sync; sleep 1
	umount $(TMP)
	tar czf $@ -C $(TMP) .

ami:
	packer build \
		-var "aws_region=$(AWS_REGION)" \
		-var "aws_vpc=$(AWS_VPC)" \
		-var "aws_subnet=$(AWS_SUBNET)" \
		-var "source_ami=$(SOURCE_AMI)" \
		-var "ami_name=$(AMI_NAME)" \
		-var "ami_description=$(AMI_DESCRIPTION)" \
		-var "builder_name=$(BUILDER_NAME)" \
		-var "tarball=$(TARBALL)" \
		./packer-cfg.json

clean:
	umount $(TMP) || true
	rm -rf $(TMP) && mkdir $(TMP)
	rm -f $(TARBALL)
	rm -rf $(PKGS)
