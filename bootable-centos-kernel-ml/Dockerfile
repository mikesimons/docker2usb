FROM bootable-centos

RUN rpm --import https://www.elrepo.org/RPM-GPG-KEY-elrepo.org && \
    rpm -Uvh http://www.elrepo.org/elrepo-release-7.0-2.el7.elrepo.noarch.rpm && \
    yum --enablerepo=elrepo-kernel install -y kernel-ml kernel-ml-devel && \
    grub2-set-default 0 && \
    yum clean all

RUN cp /boot/vmlinuz* /syslinux/vmlinuz && \
    cp /boot/initramfs* /syslinux/initrd.img