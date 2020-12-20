function assert_not_null(cond, desc)
{
	if (typeof cond === "undefined" || cond === null) {
        [NSException raise:@"Carplay Test Failed" format:desc];
	}
}

function assert_equal(a, b, desc)
{
	if (![a isEqual:b]) {
        [NSException raise:@"Carplay Test Failed" format:desc];
	}
}

function validate_live_window(window)
{
    assert_not_null(window, @"carplay window does not exist");

    // The root window was created and visible
    rootWindow = [window rootWindow];
    assert_not_null(rootWindow, @"rootWindow is null");
    assert_equal([rootWindow isHidden], @(NO), @"rootWindow is not visible");

    // The splash imageview was created
    splash_image_view = [window launchImageView];
    assert_not_null(splash_image_view, @"failed to create splash image view");

    // And it has an image
    splash_image = [splash_image_view image];
    assert_not_null(splash_image, @"failed to create splash image");

    assert_not_null([window application], @"failed to create sbapplication");
    assert_not_null([window appViewController], @"failed to create app controller");
    assert_not_null([window dockView], @"failed to create dock view");
    assert_not_null([window sceneMonitor], @"failed to create scenemonitor");
    
    // It is not in fullscreen mode
    assert_equal([window isFullscreen], @(NO), @"rootWindow started in fullscreen");

    // It starts in landscape
    assert_equal([window orientation], @(3), @"window started in unexpected orientation");
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