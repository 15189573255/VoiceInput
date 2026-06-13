//go:build darwin

#import <AppKit/AppKit.h>
#include <stdlib.h>
#include <string.h>

// mac_clipboard_get returns a newly malloc'd UTF-8 copy of the general
// pasteboard's string content, or NULL when it holds no string. The caller
// (Go) owns the buffer and must free it.
char *mac_clipboard_get(void) {
	char *result = NULL;
	@autoreleasepool {
		NSPasteboard *pb = [NSPasteboard generalPasteboard];
		NSString *s = [pb stringForType:NSPasteboardTypeString];
		if (s != nil) {
			const char *utf8 = [s UTF8String];
			if (utf8 != NULL) {
				result = strdup(utf8);
			}
		}
	}
	return result;
}

// mac_clipboard_set replaces the general pasteboard's content with the given
// UTF-8 string.
void mac_clipboard_set(const char *utf8) {
	if (utf8 == NULL) {
		return;
	}
	@autoreleasepool {
		NSString *s = [NSString stringWithUTF8String:utf8];
		if (s != nil) {
			NSPasteboard *pb = [NSPasteboard generalPasteboard];
			[pb clearContents];
			[pb setString:s forType:NSPasteboardTypeString];
		}
	}
}
