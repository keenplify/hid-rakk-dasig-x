obj-m += hid-rakk-dasig-x.o
KDIR := /lib/modules/$(shell uname -r)/build
PWD := $(shell pwd)

all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules
	zstd -f hid-rakk-dasig-x.ko

clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

install:
	cp $(PWD)/hid-rakk-dasig-x.ko.zst /lib/modules/$(shell uname -r)/kernel/drivers/hid/
	depmod -a