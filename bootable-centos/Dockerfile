FROM centos

ADD . /

RUN yum install -y kernel

RUN cp /boot/vmlinuz* /syslinux/vmlinuz && \
    cp /boot/initramfs* /syslinux/initrd.img
