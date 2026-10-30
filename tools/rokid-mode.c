// Read or set the Rokid glasses' display mode (0 = 2D, 1 = 3D side by side,
// others vendor specific) with the vendor control requests Monado's driver uses.
#include <libusb.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
	libusb_context *ctx;
	libusb_init(&ctx);
	libusb_device_handle *h = libusb_open_device_with_vid_pid(ctx, 0x04d2, 0x2002);
	if (!h) { fprintf(stderr, "glasses not found\n"); return 1; }
	unsigned char data[64] = {0};
	int r = libusb_control_transfer(h, LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
	                                0x81, 0, 1, data, sizeof data, 1000);
	if (r < 0) { printf("get mode: %s\n", libusb_error_name(r)); }
	else {
		printf("get mode (%d bytes):", r);
		for (int i = 0; i < r; i++) printf(" %02x", data[i]);
		printf("\nmode %d\n", data[1]);
	}
	if (argc > 1) {
		unsigned char one[1] = {1};
		int mode = atoi(argv[1]);
		r = libusb_control_transfer(h, LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
		                            0x1, mode, 1, one, 1, 1000);
		printf("set mode %d: %s\n", mode, r < 0 ? libusb_error_name(r) : "ok");
	}
	libusb_close(h);
	return 0;
}
