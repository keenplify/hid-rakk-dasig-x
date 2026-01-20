// SPDX-License-Identifier: GPL-2.0
/*
 * HID driver for Rakk Dasig X
 */

#include <linux/hid.h>
#include <linux/module.h>

#define USB_VENDOR_ID_RAKK 0x248A
#define USB_DEVICE_ID_RAKK_DASIG_X 0xfb01
#define USB_DEVICE_ID_RAKK_DASIG_X_DONGLE 0xfa02
#define USB_DEVICE_ID_RAKK_DASIG_X_BLUETOOTH 0x8266

#define RAKK_DASIG_X_WIRED_RDESC_LENGTH 193
#define RAKK_DASIG_X_DONGLE_RDESC_LENGTH 172
#define RAKK_DAS_X_FAULT_OFFSET 17

static const __u8 rakk_dasig_x_rdesc_fixed[] = {
    0x05, 0x01, 0x09, 0x02, 0xA1, 0x01, 0x85, 0x01, 
    0x09, 0x01, 0xA1, 0x00, 0x05, 0x09, 0x19, 0x01, 
    0x29, 0x05, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 
    0x95, 0x05, 0x81, 0x02, 0x75, 0x03, 0x95, 0x01, 
    0x81, 0x01, 0x05, 0x01, 0x09, 0x30, 0x09, 0x31, 
    0x16, 0x01, 0x80, 0x26, 0xFF, 0x7F, 0x75, 0x10, 
    0x95, 0x02, 0x81, 0x06, 0x09, 0x38, 0x15, 0x81, 
    0x25, 0x7F, 0x75, 0x08, 0x95, 0x01, 0x81, 0x06, 
    0xC0, 0xC0,
};

static const __u8 *rakk_dasig_x_report_fixup(struct hid_device *hdev, __u8 *rdesc, unsigned int *rsize) {
    bool is_bluetooth = (hdev->bus == BUS_BLUETOOTH);
    bool is_usb = (hdev->bus == BUS_USB);

    /* 1. Wired Fix: Wired mode usually needs the full descriptor swap */
    if (is_usb && hdev->product == USB_DEVICE_ID_RAKK_DASIG_X) {
        if (*rsize == RAKK_DASIG_X_WIRED_RDESC_LENGTH) {
            hid_info(hdev, "Fixing up Rakk Dasig-X (Wired) button count\n");
            *rsize = sizeof(rakk_dasig_x_rdesc_fixed);
            return rakk_dasig_x_rdesc_fixed;
        }
    }

    /* 2. Dongle & Bluetooth Surgical Fix:
     * This patches the descriptor in-place without deleting Report IDs for DPI/Media keys.
     * We look for the Button Usage Range pattern: 0x05 0x09 0x19 0x01 0x29 0x03
     */
    if ((is_bluetooth || (is_usb && hdev->product == USB_DEVICE_ID_RAKK_DASIG_X_DONGLE)) && *rsize >= 30) {
        for (int i = 0; i < *rsize - 6; i++) {
            if (rdesc[i] == 0x05 && rdesc[i+1] == 0x09 && rdesc[i+2] == 0x19 && 
                rdesc[i+3] == 0x01 && rdesc[i+4] == 0x29 && rdesc[i+5] == 0x03) {
                
                hid_info(hdev, "Surgically fixing Rakk Dasig-X (%s) buttons\n", 
                         is_bluetooth ? "Bluetooth" : "Dongle");
                
                rdesc[i+5] = 0x05; // Change Usage Max from 3 to 5
                
                /* Find the next Report Count (0x95) and change it from 5 to 5 
                 * (ensures 5 bits are allocated for 5 buttons) */
                if (rdesc[i+10] == 0x95) {
                    rdesc[i+11] = 0x05;
                }
                break; 
            }
        }
    }

    return rdesc;
}

static const struct hid_device_id rakk_dasig_x_devices[] = {
    { HID_USB_DEVICE(USB_VENDOR_ID_RAKK, USB_DEVICE_ID_RAKK_DASIG_X) },
    { HID_USB_DEVICE(USB_VENDOR_ID_RAKK, USB_DEVICE_ID_RAKK_DASIG_X_DONGLE) },
    { HID_BLUETOOTH_DEVICE(USB_VENDOR_ID_RAKK, USB_DEVICE_ID_RAKK_DASIG_X_BLUETOOTH) },
    { }
};
MODULE_DEVICE_TABLE(hid, rakk_dasig_x_devices);

static struct hid_driver rakk_dasig_x_driver = {
    .name = "rakk-dasig-x",
    .id_table = rakk_dasig_x_devices,
    .report_fixup = rakk_dasig_x_report_fixup,
};
module_hid_driver(rakk_dasig_x_driver);

MODULE_LICENSE("GPL");
MODULE_AUTHOR("Carl Eric Doromal & Aczell Bien Florencio");
MODULE_DESCRIPTION("HID driver for Rakk Dasig-X Fix");