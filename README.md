# docker2usb

Crazy shell script to convert a docker container to a bootable usb image.
Note that not any old docker image will work and this has only been validated with CentOS.

The image must be specially prepared with:
- A squashfs.sh script at the root
- kernel installed
- vmlinux and initramfs copied to /syslinux
- /syslinux/syslinux.cfg prepared
- Any additional files required for the OS to run in livecd mode (like additional dracut config for centos)

We were regularly building large bootable usb images for appliances using livecd tools.
They left something to be desired in terms of speed, ease of use and reliability so we decided to see if docker images could be abused for it.

We got it to the stage where the image would boot but did not go any further.

If you want to play with it you will need to do so on a linux system and I recommend inside a VM. The script must run as root for various reasons (mainly block device manipulation / mounting) and if it errors out but doesn't clean up then it may leave block devices or loopback devices laying around which are in finite supply and may require a reboot to free (depending on how and why it failed).

This repo is for archival purposes, made public in case it is useful to anyone as I have no intention to advance it further.
