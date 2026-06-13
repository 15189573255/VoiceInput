//go:build darwin

#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

static char *dup_or_null(NSString *s) {
	if (s == nil) {
		return NULL;
	}
	const char *utf8 = [s UTF8String];
	if (utf8 == NULL) {
		return NULL;
	}
	return strdup(utf8);
}

// mac_frontmost_name returns the localized display name of the frontmost
// application (e.g. "Code", "Safari"), or NULL.
char *mac_frontmost_name(void) {
	char *result = NULL;
	@autoreleasepool {
		NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
		if (app != nil) {
			result = dup_or_null([app localizedName]);
		}
	}
	return result;
}

// mac_frontmost_process returns the frontmost application's executable basename
// (e.g. "Code", "Google Chrome"), used for category regex matching, or NULL.
char *mac_frontmost_process(void) {
	char *result = NULL;
	@autoreleasepool {
		NSRunningApplication *app = [[NSWorkspace sharedWorkspace] frontmostApplication];
		if (app != nil) {
			NSURL *url = [app executableURL];
			if (url != nil) {
				result = dup_or_null([[url path] lastPathComponent]);
			}
			// Fall back to the localized name when the executable path is unavailable.
			if (result == NULL) {
				result = dup_or_null([app localizedName]);
			}
		}
	}
	return result;
}
