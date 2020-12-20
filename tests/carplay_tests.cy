function assert_not_null(cond, desc) {
	if (typeof cond === "undefined" || cond === null) {
        [NSException raise:@"Carplay Test Failed" format:desc];
	}
}

function test_app_library_includes_all_apps()
{
    // When an application library is created
    appLibrary = [CARApplication _newApplicationLibrary];
    assert_not_null(appLibrary, @"_newApplicationLibrary is NULL");

    // It includes apps that are normally excluded/unsupported
    appInfo = [appLibrary applicationInfoForBundleIdentifier: @"com.netflix.Netflix"];
    assert_not_null(appInfo, @"app library did not include unsupported apps");
}

test_app_library_includes_all_apps();