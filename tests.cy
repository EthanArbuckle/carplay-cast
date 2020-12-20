
function assert_not_null(a) {
	if (typeof a === "undefined" || a === null) {
		NSLog("FAIL: " + a + " === nil");
	}
}

function assert_equal(a, b) {
	if (![a isEqual:b]) {
		NSLog("FAIL: " + a + " !== " + b);
	}
}

function validate_live_window(window)
{
    assert_not_null(window);

    // The root window was created and visible
    rootWindow = [window rootWindow];
    assert_not_null(rootWindow);
    assert_equal([rootWindow isHidden], @(NO));

    // The splash imageview was created
    splash_image_view = [window launchImageView];
    assert_not_null(splash_image_view);

    // And it has an image
    splash_image = [splash_image_view image];
    assert_not_null(splash_image);

    assert_not_null([window application]);
    assert_not_null([window appViewController]);
    assert_not_null([window dockView]);
    assert_not_null([window sceneMonitor]);
    
    // It is not in fullscreen mode
    assert_equal([window isFullscreen], @(NO));

    // It starts in landscape
    assert_equal([window orientation], @(3));
}

function launch_window_device_locked()
{
    // When the device is locked
    [[SBBacklightController sharedInstance] _startFadeOutAnimationFromLockSource:1];

    // A carplay window can be opened
    [[SpringBoard sharedApplication] launchAppOnCarplay:@"com.netflix.Netflix"];

    // The window was created
    live_window = [[SpringBoard sharedApplication] liveCarplayWindow];
    validate_live_window(live_window);

    sleep(1);

    [live_window dismiss];
}

function launch_window_device_unlocked()
{
    // When the device is unlocked
    [[SBLockScreenManager sharedInstance] unlockUIFromSource:3  withOptions:@{@"SBUIUnlockOptionsTurnOnScreenFirstKey":1} ];

    // A carplay window can be opened
    [[SpringBoard sharedApplication] launchAppOnCarplay:@"com.netflix.Netflix"];

    // The window was created
    live_window = [[SpringBoard sharedApplication] liveCarplayWindow];
    validate_live_window(live_window);

    sleep(1);

    [live_window dismiss];
}


launch_window_device_locked();

sleep(1);

launch_window_device_unlocked();