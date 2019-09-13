# Makefile for building Arch Linux EC2 images with packer.io
#
# https://gitlab.com/bitfehler/archlinux-ec2

# The AWS credentials (which packer needs) are not set anywhere in this
# project. The intention is to use the "Environment variables" or "Shared
# Credentials file" approach outlined here:
# https://www.packer.io/docs/builders/amazon.html

# The AWS region/vpc/subnet in which to build the AMI. If you want the AMI to
# be build for multiple regions, please edit the packer config itself.
AWS_REGION      ?= eu-west-1
AWS_VPC         ?= vpc-1234abcd
AWS_SUBNET      ?= subnet-1234abcd

# A name for your AMI. Constraints: 3-128 alphanumeric characters, parentheses
# (()), square brackets ([]), spaces ( ), periods (.), slashes (/), dashes (-),
# single quotes ('), at-signs (@), or underscores(_)
AMI_NAME        ?= archlinux-custom-ami

# A brief description of the AMI
AMI_DESCRIPTION ?= Arch Linux AMI built with Packer.io ebssurrogate builder

# Name tag for instance and volumes used to build the AMI
BUILDER_NAME    ?= archlinux-custom-ami-builder

# Probably no need to change any of these
TARBALL = archbase.tar.gz
TMP     = ./target
PKGS    = ./pkgs

# If you add or remove packages here, also add/remove them in provision.sh
PACKAGES = $(PKGS)/cloud-init.pkg.tar.xz $(PKGS)/growpart.pkg.tar.xz

# End of variables. Feel free to study the rest, but it "should" just work...

tarball: $(TARBALL)

packages: $(PACKAGES)

$(PKGS)/%.pkg.tar.xz:
	mkdir -p "$(PKGS)"
	cd "$(PKGS)" && ( test -d "$*" || git clone https://aur.archlinux.org/$*.git )
	rm -f "$(PKGS)/$*/$*-*.pkg.tar.xz"
	cd "$(PKGS)/$*" && git pull
	cd "$(PKGS)/$*" && makepkg -f
	cp "$(PKGS)/$*/$*-"*".pkg.tar.xz" "$@"

$(TARBALL): $(PACKAGES)
	pacstrap -c $(TMP) base base-devel arch-install-scripts sudo 
	echo "en_US.UTF-8 UTF-8" >> $(TMP)/etc/locale.gen
	echo "LANG=en_US.UTF-8" >> $(TMP)/etc/locale.conf
	arch-chroot $(TMP) locale-gen
	mount --bind $(TMP) $(TMP)
	cp $(PKGS)/*.pkg.tar.xz $(TMP)/
	umount $(TMP)
	tar czf $@ -C $(TMP) .

ami:
	packer build \
		-var "aws_region=$(AWS_REGION)" \
		-var "aws_vpc=$(AWS_VPC)" \
		-var "aws_subnet=$(AWS_SUBNET)" \
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
