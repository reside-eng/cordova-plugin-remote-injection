//
//  CDVRemoteInjection.m
//

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

#import "CDVRemoteInjection.h"
#import "CDVRemoteInjectionWKWebViewDelegate.h"

@implementation CDVRemoteInjectionPlugin {
    /*
     Last time a request was made to load the web view.  Can be NULL.
     */
    NSDate *lastRequestTime;
    
    /*
     True if the user forced a reload.
     */
    BOOL forcedReload;
    
    /*
     Reference to the currently displayed alert view.  Can be NULL.
     */
    UIAlertView *alertView;
    
    /*
     * Delegate instance for the type of webView the containing app is using.
     */
    id <CDVRemoteInjectionWebViewDelegate> webViewDelegate;
}

/*
 Returns the current webView.  There's no guarantee as to the type of the 
 webView at this point.
 */
- (id) findWebView
{
#ifdef __CORDOVA_4_0_0
    return [[self webViewEngine] engineWebView];
#else
    return [self webView];
#endif
}

- (void) pluginInitialize
{
    [super pluginInitialize];
    
    // Add observers for app lifecycle events to handle background/foreground transitions
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillEnterForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
    // Read configuration for JS to inject before injecting cordova.
    NSString *value = [self settingForKey:@"CRIInjectFirstFiles"];
    if (value != NULL) {
        // Multiple files can be specified in the value, split the string on ",".
        NSMutableArray *paths = [[NSMutableArray alloc] init];
        for (id path in [value componentsSeparatedByString:@","]) {
            [paths addObject: [self trim: path]];
        }
        _injectFirstFiles = paths;
    } else {
        _injectFirstFiles = [[NSArray alloc] init];
    }
    
    value = [self settingForKey:@"CRIPageLoadPromptInterval"];
    if (value != NULL) {
        _promptInterval = [value integerValue];
    } else {
        // Defaulting to a safe value.  For most apps this will be
        // too long.  The developer should set the pref to something more
        // acceptable.  Off by default in this case doesn't seem acceptable.
        // If wanting to turn off set the value to 0 in the pref.
        _promptInterval = 10;
    }
    
    value = [self settingForKey:@"CRIShowConnectionErrorDialog"];
    if ([value isEqual: @"0"]) {
        _showConnectionErrorDialog = NO;
    } else {
        // By default the dialog is displayed.
        _showConnectionErrorDialog = YES;
    }

    id webView = [self findWebView];
    if ([webView isKindOfClass:[WKWebView class]]) {
        NSLog(@"Found WKWebView");
        webViewDelegate = [[CDVRemoteInjectionWKWebViewDelegate alloc] init];
        [webViewDelegate initializeDelegate:self];
        
        return;
    } else {
        NSLog(@"Not a supported web view implementation");
    }
}

/*
 Holy crap these APIs are verbose...
 */
- (NSString *) trim:(NSString *)s
{
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

/*
 * Reads preferences from the configuration.
 */
- (id)settingForKey:(NSString *)key
{
    return [self.commandDelegate.settings objectForKey:[key lowercaseString]];
}

/*
 * Handle app entering background - notify webview to pause external scripts gracefully
 */
- (void)applicationDidEnterBackground:(NSNotification *)notification
{
    NSLog(@"CDVRemoteInjection: App entering background, pausing external scripts");
    
    id webView = [self findWebView];
    if ([webView isKindOfClass:[WKWebView class]]) {
        WKWebView *wkWebView = (WKWebView *)webView;
        
        // Inject JavaScript to pause external scripts and prevent errors
        NSString *pauseScript = @"(function() { "
            "if (window.cordovaRemoteInjection) return; "
            "window.cordovaRemoteInjection = { backgrounded: true, originalSetInterval: window.setInterval, originalSetTimeout: window.setTimeout }; "
            "window.setInterval = function(fn, delay) { "
                "if (window.cordovaRemoteInjection.backgrounded) { "
                    "console.log('CDVRemoteInjection: Blocking setInterval during background'); "
                    "return null; "
                "} "
                "return window.cordovaRemoteInjection.originalSetInterval(fn, delay); "
            "}; "
            "window.setTimeout = function(fn, delay) { "
                "if (window.cordovaRemoteInjection.backgrounded) { "
                    "console.log('CDVRemoteInjection: Blocking setTimeout during background'); "
                    "return null; "
                "} "
                "return window.cordovaRemoteInjection.originalSetTimeout(fn, delay); "
            "}; "
            "console.log('CDVRemoteInjection: External scripts paused for backgrounding'); "
        "})();";
        
        [wkWebView evaluateJavaScript:pauseScript completionHandler:^(id result, NSError *error) {
            if (error) {
                NSLog(@"CDVRemoteInjection: Error pausing external scripts: %@", error.localizedDescription);
            }
        }];
    }
}

/*
 * Handle app entering foreground - notify webview to resume external scripts
 */
- (void)applicationWillEnterForeground:(NSNotification *)notification
{
    NSLog(@"CDVRemoteInjection: App entering foreground, resuming external scripts");
    
    id webView = [self findWebView];
    if ([webView isKindOfClass:[WKWebView class]]) {
        WKWebView *wkWebView = (WKWebView *)webView;
        
        // Inject JavaScript to resume external scripts
        NSString *resumeScript = @"(function() { "
            "if (!window.cordovaRemoteInjection) return; "
            "window.cordovaRemoteInjection.backgrounded = false; "
            "if (window.cordovaRemoteInjection.originalSetInterval) { "
                "window.setInterval = window.cordovaRemoteInjection.originalSetInterval; "
            "} "
            "if (window.cordovaRemoteInjection.originalSetTimeout) { "
                "window.setTimeout = window.cordovaRemoteInjection.originalSetTimeout; "
            "} "
            "console.log('CDVRemoteInjection: External scripts resumed from backgrounding'); "
        "})();";
        
        [wkWebView evaluateJavaScript:resumeScript completionHandler:^(id result, NSError *error) {
            if (error) {
                NSLog(@"CDVRemoteInjection: Error resuming external scripts: %@", error.localizedDescription);
            }
        }];
    }
}

/*
 * Clean up notification observers when plugin is deallocated
 */
- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end
