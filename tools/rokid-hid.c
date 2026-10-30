// Read raw input reports from the Rokid glasses' HID interface through IOHIDManager.
#include <IOKit/hid/IOHIDManager.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdio.h>

static int left = 20;
static uint8_t buf[1024];

static void cb(void *ctx, IOReturn r, void *sender, IOHIDReportType t, uint32_t id, uint8_t *rep, CFIndex len) {
	printf("%3ld id %u:", (long)len, id);
	for (CFIndex i = 0; i < len; i++) printf(" %02x", rep[i]);
	printf("\n");
	if (--left <= 0) CFRunLoopStop(CFRunLoopGetCurrent());
}

int main(int argc, char **argv) {
	if (argc > 1) left = atoi(argv[1]);
	IOHIDManagerRef m = IOHIDManagerCreate(kCFAllocatorDefault, 0);
	int vid = 0x04d2;
	CFNumberRef v = CFNumberCreate(0, kCFNumberIntType, &vid);
	CFDictionaryRef match = CFDictionaryCreate(0, (const void *[]){CFSTR(kIOHIDVendorIDKey)}, (const void *[]){v}, 1,
	                                           &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	IOHIDManagerSetDeviceMatching(m, match);
	IOReturn r = IOHIDManagerOpen(m, 0);
	printf("open manager: 0x%x\n", r);
	CFSetRef set = IOHIDManagerCopyDevices(m);
	if (!set) { printf("no devices\n"); return 1; }
	CFIndex n = CFSetGetCount(set);
	const void *devs[16];
	CFSetGetValues(set, devs);
	for (CFIndex i = 0; i < n; i++) {
		IOHIDDeviceRef d = (IOHIDDeviceRef)devs[i];
		int page = 0, usage = 0, maxin = 0;
		CFNumberGetValue(IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsagePageKey)), kCFNumberIntType, &page);
		CFNumberGetValue(IOHIDDeviceGetProperty(d, CFSTR(kIOHIDPrimaryUsageKey)), kCFNumberIntType, &usage);
		CFTypeRef mi = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDMaxInputReportSizeKey));
		if (mi) CFNumberGetValue(mi, kCFNumberIntType, &maxin);
		printf("device page %04x usage %04x maxin %d\n", page, usage, maxin);
		if (page == 0xff00) {
			IOHIDDeviceRegisterInputReportCallback(d, buf, sizeof buf, cb, 0);
			IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		}
	}
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, 5, false);
	return 0;
}
