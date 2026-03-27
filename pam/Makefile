CC = clang
CFLAGS = -Wall -Wextra -Werror -O2 -std=c11 -fPIC
LDFLAGS = -lpam
SDK = $(shell xcrun --show-sdk-path)
INCLUDES = -isysroot $(SDK)

TARGET = pam_touchbridge.so

.PHONY: all clean

all: $(TARGET)

$(TARGET): pam_touchbridge.c pam_touchbridge.h
	$(CC) $(CFLAGS) $(INCLUDES) -arch arm64 -shared -o pam_touchbridge_arm64.so pam_touchbridge.c $(LDFLAGS)
	$(CC) $(CFLAGS) $(INCLUDES) -arch x86_64 -shared -o pam_touchbridge_x86_64.so pam_touchbridge.c $(LDFLAGS)
	lipo -create pam_touchbridge_arm64.so pam_touchbridge_x86_64.so -output $(TARGET)
	@rm -f pam_touchbridge_arm64.so pam_touchbridge_x86_64.so
	@echo "Built $(TARGET) (universal binary)"

clean:
	rm -f $(TARGET) pam_touchbridge_arm64.so pam_touchbridge_x86_64.so
