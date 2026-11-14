# Build with Theos + a compatible iOS SDK on macOS or Linux.
TARGET = iphone:clang:latest:15.0
ARCHS = arm64

TWEAK_NAME = MeetLocalRecorder
MeetLocalRecorder_FILES = Tweak.xm
MeetLocalRecorder_FRAMEWORKS = UIKit AVFoundation ReplayKit CallKit Photos QuartzCore
MeetLocalRecorder_CFLAGS = -fobjc-arc -std=c++17 -Wno-deprecated-declarations \
    -DMLR_FORCE_DEFAULT_AUDIO=1 \
    -DMLR_EXPERIMENTAL_CALLKIT_SUPPRESS=0

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
# Trigger
# Trigger macos-latest
# Trigger dpkg build
# Trigger update-theos
# Fix weak self pattern
# Fix all weak self patterns
# Fix strongSelf scope
# Fix typeof(weakSelf)
# Fix __strong id
# Fix MLRController* cast
# Install ldid
