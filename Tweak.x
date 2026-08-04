#import "Tweak.h"

NSBundle *tweakBundle;
NSUserDefaults *tweakDefaults;
TWAdBlockAssetResourceLoaderDelegate *assetResourceLoaderDelegate;

static BOOL TWAdBlockEnabled(void) {
  return [tweakDefaults boolForKey:@"TWAdBlockEnabled"];
}

static BOOL TWAdBlockProxyEnabled(void) {
  return [tweakDefaults boolForKey:@"TWAdBlockProxyEnabled"];
}

static NSString *TWAdBlockProxyAddress(void) {
  NSString *proxy = [tweakDefaults boolForKey:@"TWAdBlockCustomProxyEnabled"]
                        ? [tweakDefaults stringForKey:@"TWAdBlockProxy"]
                        : PROXY_ADDR;
  return [proxy isKindOfClass:NSString.class] ? [proxy stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : @"";
}

static BOOL TWAdBlockIsUsherRequest(NSURLRequest *request) {
  return [request.URL.host caseInsensitiveCompare:@"usher.ttvnw.net"] == NSOrderedSame;
}

static NSURL *TWAdBlockHTTPProxyURL(NSString *proxy) {
  if (proxy.length == 0) return nil;
  NSURL *URL = [NSURL URLWithString:proxy];
  if (!URL || ![URL.scheme.lowercaseString hasPrefix:@"http"]) return nil;
  return URL;
}

// Server-side video ad blocking

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request {
  if (!TWAdBlockEnabled() || !request) return %orig;

  NSMutableURLRequest *mutableRequest = [request isKindOfClass:NSMutableURLRequest.class]
                                             ? (NSMutableURLRequest *)request
                                             : request.mutableCopy;
  mutableRequest.HTTPBody = [request.HTTPBody twab_requestDataForRequest:request];

  if (!TWAdBlockProxyEnabled() || !TWAdBlockIsUsherRequest(mutableRequest))
    return %orig(mutableRequest);

  NSString *proxy = TWAdBlockProxyAddress();
  if (proxy.length == 0) return %orig(mutableRequest);

  NSURL *proxyURL = TWAdBlockHTTPProxyURL(proxy);
  if (proxyURL) {
    NSURL *rewrittenURL = [mutableRequest.URL twab_URLWithProxyURL:proxyURL];
    if (rewrittenURL) mutableRequest.URL = rewrittenURL;
    return %orig(mutableRequest);
  }

  NSURLSession *proxySession = [self twab_proxySessionWithAddress:proxy];
  return proxySession ? [proxySession dataTaskWithRequest:mutableRequest] : %orig(mutableRequest);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData {
  if (!TWAdBlockEnabled() || !request) return %orig;

  NSMutableURLRequest *mutableRequest = [request isKindOfClass:NSMutableURLRequest.class]
                                             ? (NSMutableURLRequest *)request
                                             : request.mutableCopy;
  NSData *rewrittenBody = [bodyData twab_requestDataForRequest:request];

  if (!TWAdBlockProxyEnabled() || !TWAdBlockIsUsherRequest(mutableRequest))
    return %orig(mutableRequest, rewrittenBody);

  NSString *proxy = TWAdBlockProxyAddress();
  if (proxy.length == 0) return %orig(mutableRequest, rewrittenBody);

  NSURL *proxyURL = TWAdBlockHTTPProxyURL(proxy);
  if (proxyURL) {
    NSURL *rewrittenURL = [mutableRequest.URL twab_URLWithProxyURL:proxyURL];
    if (rewrittenURL) mutableRequest.URL = rewrittenURL;
    return %orig(mutableRequest, rewrittenBody);
  }

  NSURLSession *proxySession = [self twab_proxySessionWithAddress:proxy];
  return proxySession ? [proxySession uploadTaskWithRequest:mutableRequest fromData:rewrittenBody]
                      : %orig(mutableRequest, rewrittenBody);
}

%end

%hook AVURLAsset

- (instancetype)initWithURL:(NSURL *)URL options:(NSDictionary<NSString *, id> *)options {
  if (!TWAdBlockEnabled() || !TWAdBlockProxyEnabled() || !URL ||
      ![URL.scheme.lowercaseString isEqualToString:@"https"] ||
      [URL.host caseInsensitiveCompare:@"usher.ttvnw.net"] != NSOrderedSame)
    return %orig;

  NSString *proxy = TWAdBlockProxyAddress();
  if (proxy.length == 0) return %orig;

  NSURL *proxyURL = TWAdBlockHTTPProxyURL(proxy);
  if (proxyURL) {
    NSURL *rewrittenURL = [URL twab_URLWithProxyURL:proxyURL];
    return rewrittenURL ? %orig(rewrittenURL, options) : %orig;
  }

  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
  components.scheme = @"twab";
  NSURL *rewrittenURL = components.URL;
  if (!rewrittenURL) return %orig;

  if ((self = %orig(rewrittenURL, options))) {
    [self.resourceLoader setDelegate:assetResourceLoaderDelegate
                               queue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0)];
  }
  return self;
}

%end

%hook _TtC6Twitch27AssetResourceLoaderDelegate

%new
- (BOOL)handleLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSURL *URL = loadingRequest.request.URL;
  if (!URL || ![URL.scheme.lowercaseString isEqualToString:@"twab"]) return NO;

  NSURLComponents *components = [NSURLComponents componentsWithURL:URL resolvingAgainstBaseURL:NO];
  components.scheme = @"https";
  if (!components.URL) return NO;

  NSMutableURLRequest *request = loadingRequest.request.mutableCopy;
  request.URL = components.URL;

  NSString *proxy = TWAdBlockProxyAddress();
  if (proxy.length == 0) return NO;

  NSURLSession *session = [[NSURLSession alloc] twab_proxySessionWithAddress:proxy];
  if (!session) return NO;

  [[session dataTaskWithRequest:request
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                  [loadingRequest finishLoadingWithError:error];
                  return;
                }
                if (!data) {
                  NSError *emptyResponseError = [NSError errorWithDomain:@"com.level3tjg.twitchadblock"
                                                                     code:1
                                                                 userInfo:@{NSLocalizedDescriptionKey: @"Proxy returned an empty response"}];
                  [loadingRequest finishLoadingWithError:emptyResponseError];
                  return;
                }

                NSHTTPURLResponse *HTTPResponse = [response isKindOfClass:NSHTTPURLResponse.class]
                                                      ? (NSHTTPURLResponse *)response
                                                      : nil;
                AVAssetResourceLoadingContentInformationRequest *contentInfo = loadingRequest.contentInformationRequest;
                if (contentInfo) {
                  NSString *MIMEType = HTTPResponse.MIMEType ?: @"application/vnd.apple.mpegurl";
                  contentInfo.contentType = (__bridge_transfer NSString *)UTTypeCreatePreferredIdentifierForTag(
                      kUTTagClassMIMEType, (__bridge CFStringRef)MIMEType, NULL);
                  contentInfo.contentLength = HTTPResponse.expectedContentLength;
                  contentInfo.byteRangeAccessSupported = YES;
                }

                [loadingRequest.dataRequest respondWithData:data];
                [loadingRequest finishLoading];
              }] resume];
  return YES;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
  return [self handleLoadingRequest:loadingRequest] ? YES : %orig;
}

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
    shouldWaitForRenewalOfRequestedResource:(AVAssetResourceRenewalRequest *)renewalRequest {
  return [self handleLoadingRequest:renewalRequest] ? YES : %orig;
}

%end

// Client-side ad suppression using known Twitch classes only. The previous global
// Swift weak-reference interception was removed because it inspected arbitrary
// runtime pointers and could crash when Twitch or the Swift runtime changed.

%hook _TtC9TwitchKit18TKURLSessionClient

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  if (!TWAdBlockEnabled() || !data) return %orig;
  NSData *filteredData = [data twab_responseDataForRequest:dataTask.currentRequest];
  %orig(session, dataTask, filteredData ?: data);
}

%end

static void TWAdBlockClearIvar(id object, const char *name) {
  if (!object || !name) return;
  Ivar ivar = class_getInstanceVariable(object_getClass(object), name);
  if (ivar) object_setIvar(object, ivar, nil);
}

static void TWAdBlockConfigureFollowingController(id controller) {
  if (!controller) return;
  Ivar headlinerManagerIvar = class_getInstanceVariable(object_getClass(controller), "headlinerManager");
  if (headlinerManagerIvar) TWAdBlockClearIvar(controller, "displayAdStateManager");
}

%hook _TtC6Twitch23FollowingViewController

- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(_TtC12TwitchCoreUI21TWDefaultThemeManager *)themeManager {
  self = %orig;
  if (self && TWAdBlockEnabled()) TWAdBlockConfigureFollowingController(self);
  return self;
}

- (instancetype)initWithGraphQL:(_TtC9TwitchKit9TKGraphQL *)graphQL
                   themeManager:(_TtC12TwitchCoreUI21TWDefaultThemeManager *)themeManager
                  urlController:(_TtC6Twitch13URLController *)urlController {
  self = %orig;
  if (self && TWAdBlockEnabled()) TWAdBlockConfigureFollowingController(self);
  return self;
}

%end

%hook _TtC6Twitch27HeadlinerFollowingAdManager

+ (instancetype)shared {
  _TtC6Twitch27HeadlinerFollowingAdManager *shared = %orig;
  if (shared && TWAdBlockEnabled()) TWAdBlockClearIvar(shared, "displayAdStateManager");
  return shared;
}

%end

// Block update prompt

%hook TWAppUpdatePrompt
+ (void)startMonitoringSavantSettingsToShowPromptIfNeeded {}
%end

%ctor {
  tweakBundle = [NSBundle bundleWithPath:[NSBundle.mainBundle pathForResource:@"TwitchAdBlock"
                                                                       ofType:@"bundle"]];
  if (!tweakBundle)
    tweakBundle = [NSBundle
        bundleWithPath:ROOT_PATH_NS(@"/Library/Application Support/TwitchAdBlock.bundle")];

  tweakDefaults = [[NSUserDefaults alloc] initWithSuiteName:@"com.level3tjg.twitchadblock"];
  if (![tweakDefaults objectForKey:@"TWAdBlockEnabled"])
    [tweakDefaults setBool:YES forKey:@"TWAdBlockEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockProxyEnabled"])
    [tweakDefaults setBool:NO forKey:@"TWAdBlockProxyEnabled"];
  if (![tweakDefaults objectForKey:@"TWAdBlockCustomProxyEnabled"])
    [tweakDefaults setBool:NO forKey:@"TWAdBlockCustomProxyEnabled"];

  assetResourceLoaderDelegate = [[TWAdBlockAssetResourceLoaderDelegate alloc] init];
}