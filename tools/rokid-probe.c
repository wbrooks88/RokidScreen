// Dump the Rokid glasses' USB descriptors and read raw packets from the
// vendor interface, to find where the IMU data lives.
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
	int pid = argc > 1 ? (int)strtol(argv[1], 0, 16) : 0x2002;
	int iface = argc > 2 ? atoi(argv[2]) : 3;
	int count = argc > 3 ? atoi(argv[3]) : 20;
	libusb_context *ctx;
	libusb_init(&ctx);
	libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, 0x04d2, pid);
	if (!h) { fprintf(stderr, "open failed\n"); return 1; }
	struct libusb_config_descriptor *cfg;
	libusb_get_active_config_descriptor(libusb_get_device(h), &cfg);
	int in_ep = 0, in_type = 0, in_size = 64;
	for (int i = 0; i < cfg->bNumInterfaces; i++) {
		const struct libusb_interface *it = &cfg->interface[i];
		for (int a = 0; a < it->num_altsetting; a++) {
			const struct libusb_interface_descriptor *d = &it->altsetting[a];
			printf("iface %d alt %d class %02x/%02x/%02x eps %d\n", d->bInterfaceNumber, d->bAlternateSetting,
			       d->bInterfaceClass, d->bInterfaceSubClass, d->bInterfaceProtocol, d->bNumEndpoints);
			for (int e = 0; e < d->bNumEndpoints; e++) {
				const struct libusb_endpoint_descriptor *ep = &d->endpoint[e];
				printf("   ep %02x attr %02x size %d interval %d\n", ep->bEndpointAddress, ep->bmAttributes,
				       ep->wMaxPacketSize, ep->bInterval);
				if (d->bInterfaceNumber == iface && (ep->bEndpointAddress & 0x80)) {
					in_ep = ep->bEndpointAddress; in_type = ep->bmAttributes & 3; in_size = ep->wMaxPacketSize;
				}
			}
		}
	}
	if (!in_ep || count == 0) return 0;
	int r = libusb_claim_interface(h, iface);
	printf("claim iface %d: %s\n", iface, libusb_error_name(r));
	if (r) return 1;
	unsigned char buf[1024];
	for (int n = 0; n < count; n++) {
		int got = 0;
		r = in_type == 3 ? libusb_interrupt_transfer(h, in_ep, buf, in_size, &got, 1000)
		                 : libusb_bulk_transfer(h, in_ep, buf, in_size, &got, 1000);
		if (r) { printf("read: %s\n", libusb_error_name(r)); continue; }
		printf("%3d:", got);
		for (int i = 0; i < got; i++) printf(" %02x", buf[i]);
		printf("\n");
	}
	libusb_release_interface(h, iface);
	libusb_close(h);
	return 0;
}
